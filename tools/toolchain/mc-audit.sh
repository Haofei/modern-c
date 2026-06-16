#!/usr/bin/env bash
# tools/toolchain/mc-audit.sh — unified MC source-level security auditor.
#
# One parameterized lint that replaces three ~90%-identical awk scripts:
#   --mode unsafe        (S0.2) enforce + inventory the MC `unsafe` boundary
#   --mode double-fetch  (U2)   flag double-fetch / TOCTOU on user memory
#   --mode taint         (U3)   flag user-derived lengths/indices used without a bound check
#
# All three shared the same awk machinery (comment/string `strip()`, brace-depth /
# function-scope tracking, the `nth_arg`/`call_args` argument splitter, the
# `__COUNT__=N`->stderr plumbing). Consolidating them means a single fix — e.g. the
# cross-line logical-line joining below — applies to all three at once.
#
# These are *lints*, not the compiler. The authoritative gates are sema (E_UNSAFE_REQUIRED,
# the `UserSnapshot`/`Tainted<T>` types in kernel/core/uaccess.mc); this is the greppable,
# human-auditable backstop. See docs/unsafe-boundary.md, docs/uaccess.md.
#
# Shared correctness properties (the bugs this consolidation fixed):
#   * CROSS-LINE OPS: physical lines are first joined into LOGICAL lines (continuing while
#     round/square brackets are unbalanced, or when the next line is a `.method` chain), so a
#     `raw\n  .load<u8>(p)` or a multi-line `copy_from_user(us,\n  dst, src, n)` call is matched,
#     not silently skipped (a false negative in the violation check AND the inventory).
#   * `<>` DEPTH: the argument splitter counts `<`/`>` for generic depth but ignores the
#     digraphs `->`, `=>`, `<=`, `>=`, `<<`, `>>` (which are not bracket nesting), so top-level
#     comma splitting is not corrupted by an arrow/shift/compare.
#
# Exit non-zero only on a real finding (a gated unsafe op outside a region / a likely
# double-fetch / an unvalidated tainted use). A clean run prints the inventory and exits 0.
#
# Usage:
#   mc-audit.sh --mode unsafe        [DIR ...]   (default dirs: kernel std)
#   mc-audit.sh --mode double-fetch  [DIR ...]   (default dir:  kernel)
#   mc-audit.sh --mode taint         [DIR ...]   (default dir:  kernel)
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
  unsafe|double-fetch|taint) : ;;
  *) echo "mc-audit: --mode must be one of: unsafe | double-fetch | taint" >&2; exit 2 ;;
esac

# Default scan roots per mode.
if [ ${#DIRS[@]} -eq 0 ]; then
  if [ "$MODE" = unsafe ]; then DIRS=(kernel std); else DIRS=(kernel); fi
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
    double-fetch)
      # NEGATIVE TEST (must be flagged): a textbook double-fetch. `lenp` is copied in once to
      # validate, then copied in AGAIN to use — TOCTOU. The SECOND call is spelled across
      # multiple lines to prove the cross-line join surfaces it (the old per-line matcher bailed).
      cat > "$SELF_TMP/kernel/core/double_fetch_bad.mc" <<'MC'
import "kernel/core/uaccess.mc";
import "std/addr.mc";

// NEGATIVE TEST (must be flagged): a textbook double-fetch. `lenp` is copied in once to validate,
// then copied in AGAIN to actually use it — the second read can observe attacker-mutated bytes
// the first read validated.
export fn bad_double_fetch(us: *UserSpace, lenp: UserPtr<u8>, kbuf: PAddr) -> bool {
    var n1: PAddr = kbuf;
    switch copy_from_user(us, n1, lenp, 4) {   // FETCH #1: validate
        ok(v) => {}
        err(e) => { return false; }
    }
    var n2: PAddr = kbuf;
    switch copy_from_user(
        us,
        n2,
        lenp,
        4
    ) {                                         // FETCH #2 of the SAME lenp (multi-line): TOCTOU
        ok(v) => {}
        err(e) => { return false; }
    }
    return true;
}
MC
      ;;
    taint)
      # NEGATIVE TEST (must be flagged): TWO unvalidated tainted-length uses.
      #  (1) raw `.value` fed straight to a copy length.
      #  (2) a value PASSED to `checked_len` but then the ORIGINAL raw name is used as the length
      #      — the validator returns a NEW value via `ok(v)`; the input stays attacker-controlled.
      #      The old lint cleansed the input name and reported this clean (a false negative).
      cat > "$SELF_TMP/kernel/core/taint_bad.mc" <<'MC'
import "kernel/core/uaccess.mc";
import "std/addr.mc";

// NEGATIVE TEST (must be flagged): a textbook unvalidated tainted length. `n` is the raw
// user-supplied length read out of a snapshot; it is fed directly to a copy as the length WITHOUT
// passing checked_len/validate_bound — the heartbleed over-read.
export fn bad_unvalidated_len(us: *UserSpace, lenp: UserPtr<u8>, dst: PAddr, src: UserPtr<u8>) -> bool {
    var n: u8 = 0;
    switch fetch_user(u8, us, lenp) {
        ok(snap) => { n = snap.value; }   // tainted: raw user length
        err(e) => { return false; }
    }
    switch copy_from_user(us, dst, src, n) {   // BUG: `n` drives the copy length, no bound check
        ok(v) => {}
        err(e) => { return false; }
    }
    return true;
}

// NEGATIVE TEST (must be flagged): the validate-then-use-the-WRONG-value bug. `m` IS passed to
// checked_len, but the validated value comes back as `cv` via `ok(cv)`; the code then uses the
// raw `m` (still attacker-controlled) as the copy length. Cleansing the input name `m` would be
// the false negative this lint fix closes.
export fn bad_validate_wrong_value(us: *UserSpace, lenp: UserPtr<u8>, dst: PAddr, src: UserPtr<u8>, lim: u8) -> bool {
    var m: u8 = 0;
    switch fetch_user(u8, us, lenp) {
        ok(snap) => { m = snap.value; }
        err(e) => { return false; }
    }
    var cv: u8 = 0;
    switch checked_len(u8, tainted(m), lim) {
        ok(v) => { cv = v; }              // `cv` is the trusted value
        err(e) => { return false; }
    }
    switch copy_from_user(us, dst, src, m) {   // BUG: uses raw `m`, NOT the validated `cv`
        ok(v) => {}
        err(e) => { return false; }
    }
    return true;
}
MC
      ;;
  esac
  DIRS=("$SELF_TMP/kernel")
  [ "$MODE" = unsafe ] && DIRS=("$SELF_TMP/kernel" "$SELF_TMP/std")
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
# lines (a `raw\n .load<u8>(p)` method chain, or a multi-line `copy_from_user(us,\n dst, src, n)`
# arg list) is matched, not silently skipped — the false negative the per-physical-line lints had.
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
  else if (MODE=="double-fetch") do_doublefetch(logical, startfnr)
  else if (MODE=="taint")        do_taint(logical, startfnr)
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
  delete tainted; delete tline; snapvar=""; sawfetch=0; sawvalidator=0
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
  else if (MODE=="double-fetch") end_doublefetch()
  else if (MODE=="taint")        end_taint()
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

# ===================== MODE: double-fetch (U2) =====================

# The user pointer is the 3rd arg of copy_from_user{,_pt} / fetch_user{,_pt}.
function user_src(l,   a) {
  a = call_args(l, "(copy_from_user_pt|copy_from_user|fetch_user_pt|fetch_user)[ \t]*\\(")
  if (a == "<<NONE>>") return ""
  return nth_arg(a, 3)
}

function do_doublefetch(l, startfnr,   src) {
  if (!infn && depth==0 && match(l, /(^|[^_[:alnum:]])fn[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
    nm = substr(l, RSTART, RLENGTH); sub(/^.*fn[ \t]+/, "", nm)
    fnname = nm; infn=1; fnopen=depth
    delete seen; delete seenline
  }

  src = user_src(l)
  if (src != "" && infn) {
    ncalls++
    if (src in seen) {
      findings++
      printf("DOUBLE-FETCH  %s:%d  fn `%s` re-reads the same UserPtr `%s` (first at line %d) — copy it in once via fetch_user/UserSnapshot\n",
             FILENAME, startfnr, fnname, src, seenline[src]) > "/dev/stderr"
    } else { seen[src]=1; seenline[src]=startfnr }
  } else if (src != "") {
    ncalls++
  }

  brace_update(l)
  if (infn && depth <= fnopen) { infn=0; fnname=""; delete seen; delete seenline }
}

function end_doublefetch() {
  print  "============== MC double-fetch / TOCTOU audit (U2) =============="
  printf("scanned %d .mc file(s); %d user-read call site(s) (copy_from_user{,_pt} / fetch_user{,_pt})\n\n", nfiles, ncalls)
  if (findings==0)
    print "RESULT: clean — no function copies the same UserPtr in more than once."
  else
    printf("RESULT: %d likely double-fetch(es) found (see DOUBLE-FETCH lines on stderr).\n", findings)
  print  "================================================================"
  print "__COUNT__=" findings > "/dev/stderr"
}

# ===================== MODE: taint (U3) =====================

function do_taint(l, startfnr,   a, s, lhs, seg, base, ch, rhs, nmx, ca, lenarg, sub_re_idx, cmp_l, cmp_r) {
  if (!infn && depth==0 && match(l, /(^|[^_[:alnum:]])fn[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
    nm = substr(l, RSTART, RLENGTH); sub(/^.*fn[ \t]+/, "", nm)
    fnname = nm; infn=1; fnopen=depth
    delete tainted; delete tline; snapvar=""; sawfetch=0; sawvalidator=0
  }

  if (infn) {
    # ---- VALIDATOR: a tainted name passed to checked_len/checked_index/validate_bound does NOT
    #      cleanse the INPUT name — the validator returns a NEW trusted value via its `ok(v)` arm.
    #      We record that a validator was seen on this line; the NEXT `ok(NAME) =>` arm names the
    #      trusted binding, which is simply never tainted (so nothing to do). The original tainted
    #      input STAYS tainted — using it raw afterward is still a finding. (This is the FN fix:
    #      the old lint deleted the input name`s taint here.)
    a = call_args(l, "(checked_len|checked_index|validate_bound)[ \t]*\\(")
    if (a != "<<NONE>>") sawvalidator=1

    # ---- snapshot binding name from an `ok(SNAP)` arm. After a fetch it names the snapshot var;
    #      after a validator it names the TRUSTED (untainted) value — ensure it is not tainted.
    if (match(l, /ok[ \t]*\([ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\)[ \t]*=>/)) {
      s = l; sub(/^.*ok[ \t]*\([ \t]*/, "", s); sub(/[ \t]*\).*$/, "", s)
      if (sawfetch) { snapvar = s; sawfetch = 0 }
      else if (sawvalidator) { delete tainted[s]; delete tline[s]; sawvalidator=0 }
    }

    # ---- TAINT SOURCES ----
    if (match(l, /(^|[ \t])(var|let)[ \t]+[A-Za-z_][A-Za-z0-9_]*/) && \
        l ~ /(copy_from_user|copy_from_user_pt|fetch_user|fetch_user_pt)[ \t]*\(/ && l ~ /=/) {
      lhs = l; sub(/^.*(var|let)[ \t]+/, "", lhs); sub(/[ \t:=].*$/, "", lhs)
      if (lhs != "") { tainted[lhs]=1; tline[lhs]=startfnr }
    }

    # `X = <SNAP>.value` taints X.
    if (match(l, /[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*[A-Za-z_][A-Za-z0-9_]*\.value([^A-Za-z0-9_]|$)/)) {
      seg = substr(l, RSTART, RLENGTH)
      lhs = seg; sub(/[ \t]*=.*$/, "", lhs); gsub(/[ \t]/, "", lhs)
      base = seg; sub(/^.*=[ \t]*/, "", base); sub(/\.value.*$/, "", base); gsub(/[ \t]/, "", base)
      ch = substr(l, RSTART-1, 1)
      if (base != "" && (base == snapvar || base ~ /snap/) && ch !~ /[<>=!]/) {
        if (lhs ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { tainted[lhs]=1; tline[lhs]=startfnr }
      }
    }

    # taint PROPAGATION: `let/var X = <expr mentioning a tainted name>` taints X.
    if (l ~ /(^|[ \t])(var|let)[ \t]+[A-Za-z_][A-Za-z0-9_]*/ && l ~ /=/) {
      rhs = l; sub(/^.*=[ \t]*/, "", rhs)
      lhs = l; sub(/=.*$/, "", lhs); sub(/^.*(var|let)[ \t]+/, "", lhs)
      gsub(/[ \t]/, "", lhs); sub(/:.*$/, "", lhs)
      for (nmx in tainted) {
        if (nmx != lhs && mentions(rhs, nmx)) { tainted[lhs]=1; tline[lhs]=startfnr }
      }
    }

    # ---- SINKS ----
    # (1) length arg (4th) of a copy_*_user call
    ca = call_args(l, "(copy_from_user_pt|copy_from_user|copy_to_user_pt|copy_to_user)[ \t]*\\(")
    if (ca != "<<NONE>>") {
      lenarg = nth_arg(ca, 4)
      for (nmx in tainted) {
        if (mentions(lenarg, nmx)) {
          findings++
          printf("TAINT  %s:%d  fn `%s` uses user-derived `%s` (tainted at line %d) as a copy LENGTH without checked_len/validate_bound\n",
                 FILENAME, startfnr, fnname, nmx, tline[nmx]) > "/dev/stderr"
          delete tainted[nmx]; delete tline[nmx]
        }
      }
    }

    # (2) subscript: ...[ NAME ]
    for (nmx in tainted) {
      sub_re_idx = "\\[[ \t]*" nmx "([ \t]*\\]|[^A-Za-z0-9_])"
      if (l ~ sub_re_idx) {
        findings++
        printf("TAINT  %s:%d  fn `%s` uses user-derived `%s` (tainted at line %d) as an array INDEX without checked_index/validate_bound\n",
               FILENAME, startfnr, fnname, nmx, tline[nmx]) > "/dev/stderr"
        delete tainted[nmx]; delete tline[nmx]
      }
    }

    # (3) loop bound: `while ... NAME (< <= > >=) ...`
    if (l ~ /(^|[^A-Za-z0-9_])while([^A-Za-z0-9_]|$)/) {
      for (nmx in tainted) {
        cmp_l = "(^|[^A-Za-z0-9_])" nmx "[ \t]*(<|<=|>|>=)"
        cmp_r = "(<|<=|>|>=)[ \t]*" nmx "([^A-Za-z0-9_]|$)"
        if (l ~ cmp_l || l ~ cmp_r) {
          findings++
          printf("TAINT  %s:%d  fn `%s` uses user-derived `%s` (tainted at line %d) as a LOOP BOUND without checked_len/validate_bound\n",
                 FILENAME, startfnr, fnname, nmx, tline[nmx]) > "/dev/stderr"
          delete tainted[nmx]; delete tline[nmx]
        }
      }
    }

    if (l ~ /(fetch_user|fetch_user_pt)[ \t]*\(/) { sawfetch=1; nfetch++ }
    else if (l ~ /(copy_from_user|copy_from_user_pt)[ \t]*\(/) { nfetch++ }
  }

  brace_update(l)
  if (infn && depth <= fnopen) { infn=0; fnname=""; delete tainted; delete tline; snapvar=""; sawfetch=0; sawvalidator=0 }
}

function end_taint() {
  print  "============== MC tainted length/index audit (U3) =============="
  printf("scanned %d .mc file(s); %d user-read site(s) (copy_from_user{,_pt} / fetch_user{,_pt})\n\n", nfiles, nfetch)
  if (findings==0)
    print "RESULT: clean — no user-derived value reaches a length/index/loop-bound without a validator."
  else
    printf("RESULT: %d unvalidated tainted use(s) found (see TAINT lines on stderr).\n", findings)
  print  "================================================================"
  print "__COUNT__=" findings > "/dev/stderr"
}
' $FILES 2> "$TMP"

# Surface the per-mode finding lines (awk wrote them to stderr/$TMP).
grep -E '^(VIOLATION|DOUBLE-FETCH|TAINT)' "$TMP" >&2 || true
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
