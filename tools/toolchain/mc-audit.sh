#!/usr/bin/env bash
# tools/toolchain/mc-audit.sh — unified MC source-level security auditor.
#
# One parameterized lint for retained source-level security checks:
#   --mode unsafe        (S0.2) enforce + inventory the MC `unsafe` boundary
#   --mode capability-mint flag direct capability/right mint or root authority
#        creation outside the approved authority roots
#
# These modes share the same awk machinery (comment/string `strip()`, brace-depth /
# function-scope tracking, the `nth_arg`/`call_args` argument splitter, the
# `__COUNT__=N`->stderr plumbing). Consolidating them means a single fix — e.g. the
# cross-line logical-line joining below — applies to all three at once.
#
# These are *lints*, not the compiler. The authoritative gates are sema
# (E_UNSAFE_REQUIRED) and capability/rights type boundaries; this is the
# greppable, human-auditable backstop. See docs/unsafe-boundary.md.
#
# Shared correctness properties (the bugs this consolidation fixed):
#   * CROSS-LINE OPS: physical lines are first joined into LOGICAL lines (continuing while
#     round/square brackets are unbalanced, or when the next line is a `.method` chain), so a
#     `raw\n  .load<u8>(p)` is matched,
#     not silently skipped (a false negative in the violation check AND the inventory).
#   * `<>` DEPTH: the argument splitter counts `<`/`>` for generic depth but ignores the
#     digraphs `->`, `=>`, `<=`, `>=`, `<<`, `>>` (which are not bracket nesting), so top-level
#     comma splitting is not corrupted by an arrow/shift/compare.
#
# Exit non-zero only on a real finding (a gated unsafe op outside a region or an
# unapproved capability mint). A clean run prints the inventory and exits 0.
#
# Usage:
#   mc-audit.sh --mode unsafe        [DIR ...]   (default dirs: kernel std)
#   mc-audit.sh --mode capability-mint [DIR ...] (default dirs: kernel std tests/support)
#   mc-audit.sh --mode MODE --self-test          (run the built-in negative fixture)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MODE=""
self_test=0
DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --mode=*) MODE="${1#--mode=}"; shift ;;
    --self-test) self_test=1; shift ;;
    *) DIRS+=("$1"); shift ;;
  esac
done

case "$MODE" in
  unsafe|capability-mint) : ;;
  *) echo "mc-audit: --mode must be one of: unsafe | capability-mint" >&2; exit 2 ;;
esac

# Default scan roots per mode.
if [ ${#DIRS[@]} -eq 0 ]; then
  DIRS=(kernel std)
  [ "$MODE" = capability-mint ] && DIRS=(kernel std tests/support)
fi

SELF_TMP=""
if [ "$self_test" = 1 ]; then
  SELF_TMP="$(mktemp -d)"
  mkdir -p "$SELF_TMP/kernel/core"
  case "$MODE" in
    unsafe)
      # NEGATIVE TEST (must be flagged): a gated unsafe op (`raw.load`) OUTSIDE any unsafe
      # region. The cross-line form is used on purpose: the `.load` sits on its own line, so a
      # per-physical-line matcher would MISS it — the join makes it visible.
      cat > "$SELF_TMP/kernel/core/unsafe_bad.mc" <<'MC'
import "std/addr.mc";

// NEGATIVE TEST (must be flagged): `raw.load` is a gated unsafe op; here it sits OUTSIDE any
// unsafe block. Sema would reject it (E_UNSAFE_REQUIRED); this lint must flag it too — and the
// `.load` is on a continuation line to prove cross-line ops are joined before matching.
export fn bad_unsafe_outside(p: PAddr) -> u8 {
    return raw
        .load<u8>(p);
}
MC
      ;;
    capability-mint)
      mkdir -p "$SELF_TMP/tests/support"
      cat > "$SELF_TMP/tests/support/capability.mc" <<'MC'
pub linear opaque struct BootAuthority { marker: u32 }
pub fn boot_authority_unchecked() -> BootAuthority { return .{ .marker = 1 }; }
pub fn cap_mint(comptime R: type, auth: *BootAuthority, resource: R) -> R { return resource; }
pub fn rcap_mint(comptime R: type, auth: *BootAuthority, resource: R, rights: u32) -> R { return resource; }
MC
      mkdir -p "$SELF_TMP/std"
      cat > "$SELF_TMP/std/rights.mc" <<'MC'
pub linear opaque struct RightsAuthority { marker: u32 }
pub fn rights_authority_unchecked() -> RightsAuthority { return .{ .marker = 1 }; }
pub fn rights_grant(auth: *RightsAuthority, bits: u32) -> u32 { return bits; }
pub fn rights_single(auth: *RightsAuthority, bit: u32) -> u32 { return bit; }
MC
      mkdir -p "$SELF_TMP/kernel/driver"
      cat > "$SELF_TMP/kernel/driver/bad_mint.mc" <<'MC'
import "tests/support/capability.mc";
import "std/rights.mc";

// NEGATIVE TEST (must be flagged): ordinary kernel code must not directly call the
// privileged setup-time mint/root primitives. Authority should be delegated from
// the boot authority root instead.
export fn bad_driver_mint() -> usize {
    var boot: BootAuthority = boot_authority_unchecked();
    var rights_root: RightsAuthority = rights_authority_unchecked();
    let rights: u32 = rights_grant(&rights_root, 0x3);
    return rcap_mint(usize, &boot, cap_mint(usize, &boot, 0x1000), rights);
}
MC
      ;;
  esac
  DIRS=("$SELF_TMP/kernel")
  [ "$MODE" = unsafe ] && DIRS=("$SELF_TMP/kernel" "$SELF_TMP/std")
  [ "$MODE" = capability-mint ] && DIRS=("$SELF_TMP/kernel" "$SELF_TMP/std" "$SELF_TMP/tests/support")
fi

FILES=$(find "${DIRS[@]}" -name '*.mc' 2>/dev/null | sort)
TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; [ -n "$SELF_TMP" ] && rm -rf "$SELF_TMP"; }
trap cleanup EXIT

if [ -z "$FILES" ]; then
  echo "mc-audit ($MODE): no .mc files under: ${DIRS[*]}" >&2
  exit 0
fi

awk -v MODE="$MODE" '
# ===================== shared awk library =====================

# Strip // comments and string/char literal contents so tokens inside them are not counted.
function strip(line,   out, i, c, n, instr, inchr) {
  out=""; n=length(line); instr=0; inchr=0
  for (i=1; i<=n; i++) {
    c=substr(line,i,1)
    if (instr) { if (c=="\"") instr=0; continue }
    if (inchr) { if (c=="\x27") inchr=0; continue }
    if (c=="\"") { instr=1; continue }
    if (c=="\x27") { inchr=1; continue }
    if (c=="/" && substr(line,i+1,1)=="/") break
    out=out c
  }
  return out
}

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Round/square bracket balance of a stripped line (used to decide line continuation). We do NOT
# count `<>` here — `<` / `>` are ambiguous (compare/shift) and would mis-join.
function bracket_delta(l,   i, c, d) {
  d=0
  for (i=1; i<=length(l); i++) {
    c=substr(l,i,1)
    if (c=="(" || c=="[") d++
    else if (c==")" || c=="]") d--
  }
  return d
}

# Top-level (depth-0) nth comma-separated arg of a call-argument string. Tracks (), [], and <>
# generic depth, but IGNORES the digraphs -> => <= >= << >> so an arrow/shift/compare inside an
# argument does not corrupt the depth.
function nth_arg(args, k,   i, c, c2, cp, depth, cur, idx) {
  depth=0; idx=1; cur=""
  for (i=1; i<=length(args); i++) {
    c=substr(args,i,1); c2=substr(args,i+1,1); cp=(i>1?substr(args,i-1,1):"")
    if (c=="(" || c=="[") depth++
    else if (c==")" || c=="]") depth--
    else if (c=="<") {
      if (c2=="<" || c2=="=") { cur=cur c c2; i++; continue }   # << or <= : not a bracket
      depth++
    }
    else if (c==">") {
      if (cp=="-" || cp=="=") { cur=cur c; continue }            # -> or => : not a bracket
      if (c2==">" || c2=="=") { cur=cur c c2; i++; continue }     # >> or >= : not a bracket
      depth--
    }
    else if (c=="," && depth==0) { if (idx==k) return trim(cur); idx++; cur=""; continue }
    cur=cur c
  }
  if (idx==k) return trim(cur)
  return ""
}

# The argument list of the FIRST occurrence of a call matching `re` on a (stripped, already
# line-joined) line. Returns "<<NONE>>" if absent. Because logical lines are pre-joined, a call
# argument list never spans the boundary here.
function call_args(l, re,   rest, depth, i, c, end, args) {
  if (!match(l, re)) return "<<NONE>>"
  rest = substr(l, RSTART+RLENGTH)
  depth=0; end=0; args=""
  for (i=1; i<=length(rest); i++) {
    c=substr(rest,i,1)
    if (c=="(") depth++
    else if (c==")") { if (depth==0) { end=1; break } depth-- }
    args=args c
  }
  if (!end) return "<<NONE>>"
  return args
}

# Does the (stripped) line mention bareword NAME at a token boundary?
function mentions(l, name,   re) {
  re = "(^|[^A-Za-z0-9_])" name "([^A-Za-z0-9_]|$)"
  return (l ~ re)
}

# ===================== logical-line buffering (cross-line fix) =====================
# Physical lines are joined into LOGICAL lines before any matching, so a construct split across
# lines (a `raw\n .load<u8>(p)` method chain) is matched, not silently
# skipped — the false negative the per-physical-line lints had.
#
# A physical line CONTINUES the current logical line when ANY of:
#   * round/square brackets are still open in the buffer  (`bufdepth > 0`), or
#   * the buffer ends on a dangling continuation token (a trailing `.`, `,`, or binary operator),
#     so the statement clearly continues, or
#   * the *new* stripped line itself begins with `.`     (a `.method(...)` chain continuation).
# Otherwise the buffer is a complete logical line: process it, then start a fresh buffer.
#
# A logical line is processed once; reports use the FNR of its FIRST physical line (`bufstart`),
# where the construct textually begins. Brace-depth / scope tracking advances per LOGICAL line.

function process(logical, startfnr) {
  if (MODE=="unsafe")            do_unsafe(logical, startfnr)
  else if (MODE=="capability-mint") do_capability_mint(logical, startfnr)
}

# True if the buffered logical line is incomplete and the next physical line `nsl` continues it.
function continues(nsl,   endbuf, lead) {
  if (buf == "") return 0
  if (bufdepth > 0) return 1
  endbuf = buf; sub(/[ \t]+$/, "", endbuf)
  if (endbuf ~ /[.,+\-*\/%&|^=]$/) return 1          # dangling dot / comma / operator
  lead = nsl; sub(/^[ \t]+/, "", lead)
  if (lead ~ /^\./) return 1                          # next line is a `.method` chain
  return 0
}

FNR==1 {
  # Flush any buffer carried from the previous file (a balanced file ends balanced).
  if (buf != "") { process(buf, bufstart); buf=""; bufdepth=0 }
  nfiles++
  depth=0; unsafe_open=0; unsafe_min=0
  infn=0; fnname=""; fnopen=0
  delete seen; delete seenline
}

{
  sl = strip($0)
  if (continues(sl)) {
    buf = buf " " sl; bufdepth += bracket_delta(sl)
  } else {
    if (buf != "") process(buf, bufstart)
    buf = sl; bufstart = FNR; bufdepth = bracket_delta(sl)
  }
}

END {
  if (buf != "") { process(buf, bufstart); buf="" }
  if (MODE=="unsafe")            end_unsafe()
  else if (MODE=="capability-mint") end_capability_mint()
}

# ===================== brace/scope helpers (shared) =====================
# Track brace depth + unsafe-region / function scope. Called by each mode at the END of handling a
# logical line (so a `{` that OPENS a region on the same line counts AFTER the line is examined).

function brace_update(l,   ob, cb, to, tc) {
  to=l; ob=gsub(/[{]/, "&", to); tc=l; cb=gsub(/[}]/, "&", tc)
  depth += ob - cb
  if (depth < 0) depth=0
}

# ===================== MODE: unsafe (S0.2) =====================

function ureport(cat, inside, gated, startfnr) {
  ncat[cat]++
  if (gated && !inside) {
    violations++
    printf("VIOLATION  %s:%d  gated unsafe op `%s` OUTSIDE an unsafe/unsafe_contract region\n",
           FILENAME, startfnr, cat) > "/dev/stderr"
  }
}

function do_unsafe(l, startfnr,   opens_unsafe, inside, is_defn, cur) {
  opens_unsafe=0
  if (l ~ /(^|[^_[:alnum:]])unsafe([^_[:alnum:]]|$)/) opens_unsafe=1
  if (l ~ /#\[[ \t]*unsafe_contract/) opens_unsafe=1

  inside = (unsafe_open && depth >= unsafe_min) || opens_unsafe
  is_defn = (l ~ /(^|[^_[:alnum:]])fn[ \t]+[A-Za-z_]/)

  cur=l; while (match(cur, /raw[ \t]*\.[ \t]*(load|store)[ \t]*</)) { ureport("raw_load_store", inside, 1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /mmio[ \t]*\.[ \t]*map[ \t]*</)) { ureport("mmio_map", inside, 1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /raw[ \t]*\.[ \t]*ptr[ \t]*</)) { ureport("raw_ptr", inside, 0, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /\.[ \t]*offset[ \t]*\(/)) { ureport("raw_offset", inside, 1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /forget_unchecked[ \t]*\(/)) { ureport("forget_unchecked", inside, is_defn?0:1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /arc_get_mut[ \t]*\(/)) { ureport("arc_get_mut", inside, is_defn?0:1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /(^|[^_[:alnum:]])asm[ \t]+(precise|opaque|volatile)/)) { ureport("asm", inside, 1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /unchecked[ \t]*\.[ \t]*(add|sub|mul|shl)/)) { ureport("unchecked_arith", inside, 1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /assume_noalias_unchecked[ \t]*\(/)) { ureport("assume_noalias", inside, 1, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /bitcast[ \t]*</)) { ureport("bitcast", inside, 0, startfnr); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /(^|[^_[:alnum:]])uninit([^_[:alnum:]]|$)/)) { ureport("uninit", inside, 0, startfnr); cur=substr(cur, RSTART+RLENGTH) }

  if (opens_unsafe && !unsafe_open) { unsafe_min=depth+1; unsafe_open=1 }
  brace_update(l)
  if (unsafe_open && depth < unsafe_min) { unsafe_open=0; unsafe_min=0 }
}

function end_unsafe(   tot) {
  print  "================ MC unsafe-boundary audit (S0.2) ================"
  printf("scanned %d .mc files\n\n", nfiles)
  print  "Audited unsafe sites by category (count of occurrences):"
  printf("  raw.load / raw.store      %5d   (unsafe block — type-punned raw/MMIO access)\n", ncat["raw_load_store"])
  printf("  mmio.map                  %5d   (unsafe block — mint typed MMIO view)\n", ncat["mmio_map"])
  printf("  raw.ptr                   %5d   (mint typed *mut from addr; deref is the checked part)\n", ncat["raw_ptr"])
  printf("  raw-many .offset()        %5d   (unsafe block — raw pointer arithmetic)\n", ncat["raw_offset"])
  printf("  forget_unchecked          %5d   (unsafe block — drop linear w/o release)\n", ncat["forget_unchecked"])
  printf("  arc_get_mut               %5d   (unsafe block — aliasable *mut from refcount)\n", ncat["arc_get_mut"])
  printf("  inline asm                %5d   (unsafe block; precise form needs a contract)\n", ncat["asm"])
  printf("  unchecked.{add,sub,..}    %5d   (#[unsafe_contract(no_overflow)])\n", ncat["unchecked_arith"])
  printf("  assume_noalias_unchecked  %5d   (#[unsafe_contract(noalias)])\n", ncat["assume_noalias"])
  printf("  bitcast<T>                %5d   (alias-safe memcpy reinterpret; tracked)\n", ncat["bitcast"])
  printf("  uninit                    %5d   (unspecified-not-UB storage; must write first)\n", ncat["uninit"])
  tot = ncat["raw_load_store"]+ncat["mmio_map"]+ncat["raw_ptr"]+ncat["raw_offset"] \
      + ncat["forget_unchecked"]+ncat["arc_get_mut"]+ncat["asm"]+ncat["unchecked_arith"] \
      + ncat["assume_noalias"]+ncat["bitcast"]+ncat["uninit"]
  printf("  --------------------------------\n  TOTAL                     %5d\n\n", tot)
  if (violations==0)
    print "RESULT: clean — every unsafe op sits inside an unsafe / unsafe_contract region."
  else
    printf("RESULT: %d unsafe op(s) found OUTSIDE an unsafe region (see VIOLATION lines on stderr).\n", violations)
  print  "================================================================"
  print "__COUNT__=" violations > "/dev/stderr"
}

# ===================== MODE: capability-mint =====================

function approved_capability_mint_file(file) {
  return (file ~ /(^|\/)tests\/support\/capability\.mc$/ || file ~ /(^|\/)std\/rights\.mc$/)
}

function do_capability_mint(l, startfnr,   cur, call) {
  if (approved_capability_mint_file(FILENAME)) return
  cur = l
  while (match(cur, /(^|[^A-Za-z0-9_])(cap_mint|rcap_mint|rights_grant|rights_single|boot_authority_unchecked|rights_authority_unchecked)[ \t]*\(/)) {
    call = substr(cur, RSTART, RLENGTH)
    if (call ~ /rcap_mint/) nrcapmint++
    else if (call ~ /cap_mint/) ncapmint++
    else if (call ~ /rights_grant|rights_single/) nrightsmint++
    else nauthroot++
    findings++
    printf("CAP-MINT  %s:%d  direct capability/right mint `%s` outside the approved authority roots; delegate from the boot authority root instead\n",
           FILENAME, startfnr, trim(call)) > "/dev/stderr"
    cur = substr(cur, RSTART + RLENGTH)
  }
}

function end_capability_mint() {
  print  "============== MC capability mint audit ===================="
  printf("scanned %d .mc file(s)\n\n", nfiles)
  printf("Unapproved direct mint call sites:\n")
  printf("  cap_mint                  %5d\n", ncapmint)
  printf("  rcap_mint                 %5d\n", nrcapmint)
  printf("  rights_grant/single       %5d\n", nrightsmint)
  printf("  root authority creation   %5d\n\n", nauthroot)
  if (findings==0)
    print "RESULT: clean — no source directly calls capability/right mint or root authority creation outside the approved authority roots."
  else
    printf("RESULT: %d unapproved capability/right mint call(s) found (see CAP-MINT lines on stderr).\n", findings)
  print  "================================================================"
  print "__COUNT__=" findings > "/dev/stderr"
}
' $FILES 2> "$TMP"

# Surface the per-mode finding lines (awk wrote them to stderr/$TMP).
grep -E '^(VIOLATION|CAP-MINT)' "$TMP" >&2 || true
count=$(grep -o '__COUNT__=[0-9]*' "$TMP" | head -1 | cut -d= -f2)
count=${count:-0}

# unsafe mode also prints the FFI/extern inventory (declaration count, not per-call ops).
if [ "$MODE" = unsafe ]; then
  echo
  echo "FFI / extern surface (trust boundary, declaration count):"
  extern_count=$(grep -rhn '\bextern\b' "${DIRS[@]}" --include='*.mc' 2>/dev/null | wc -l | tr -d ' ')
  printf "  extern declarations       %5s   (FFI boundary; callee correctness is not MC-checked)\n" "${extern_count}"
  echo
fi

exit $(( count > 0 ? 1 : 0 ))
