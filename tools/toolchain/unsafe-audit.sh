#!/usr/bin/env bash
# tools/toolchain/unsafe-audit.sh — S0.2: enforce + inventory the MC `unsafe` boundary.
#
# The MC front-end already *type-enforces* the unsafe boundary: raw.load/store,
# mmio.map, raw-many .offset, inline `asm`, forget_unchecked, and arc_get_mut are
# rejected outside an `unsafe { … }` block with E_UNSAFE_REQUIRED, and the
# unchecked/noalias/precise-asm operations are rejected outside a matching
# `#[unsafe_contract(...)]` region (E_UNCHECKED_OUTSIDE_CONTRACT /
# E_PRECISE_ASM_CONTRACT). See docs/unsafe-boundary.md.
#
# This script is the *independent source-level auditor* of that boundary. It:
#   1. flags any unsafe op that sits OUTSIDE an `unsafe`/`unsafe_contract` region
#      (a sound front-end never lets one compile, so a hit is either a gap in
#      this lint's brace tracking or a real escape — either way, worth seeing);
#   2. prints the inventory of audited unsafe sites in kernel/ + std/, counted by
#      category, so the unsafe surface is reviewed, not just rejected-when-misused.
#
# It is a *lint*, not the compiler: it parses with awk (comment/brace tracking),
# so it is deliberately conservative. The authoritative gate is sema; this gives
# the greppable, human-auditable view.
#
# Exit non-zero only if an unsafe op is found OUTSIDE any unsafe region (a real
# boundary violation). A clean run lists the inventory and exits 0.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DIRS=(kernel std)

FILES=$(find "${DIRS[@]}" -name '*.mc' | sort)
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

awk '
# Strip // comments and string/char literal contents so tokens inside them are
# not counted. Returns the code-only portion of the line.
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

# gated=1 ops require an `unsafe`/`unsafe_contract` region (sema rejects them outside
# one). gated=0 ops are tracked for the inventory but are legal outside unsafe
# (raw.ptr mints a pointer — the deref is the checked part; uninit is
# unspecified-not-UB; bitcast is alias-safe memcpy). Only a gated op outside a
# region is a real boundary VIOLATION.
function report(cat, inside, gated) {
  ncat[cat]++
  if (gated && !inside) {
    violations++
    printf("VIOLATION  %s:%d  gated unsafe op `%s` OUTSIDE an unsafe/unsafe_contract region\n", FILENAME, FNR, cat) > "/dev/stderr"
  }
}

BEGIN {
  split("raw_load_store mmio_map raw_ptr raw_offset forget_unchecked arc_get_mut asm unchecked_arith assume_noalias bitcast uninit", K, " ")
  for (i in K) ncat[K[i]]=0
  nfiles=0; violations=0; depth=0; unsafe_open=0; unsafe_min=0
}

FNR==1 { nfiles++; depth=0; unsafe_open=0; unsafe_min=0 }

{
  l=strip($0)

  opens_unsafe=0
  if (l ~ /(^|[^_[:alnum:]])unsafe([^_[:alnum:]]|$)/) opens_unsafe=1
  if (l ~ /#\[[ \t]*unsafe_contract/) opens_unsafe=1

  inside = (unsafe_open && depth >= unsafe_min) || opens_unsafe

  # A function *definition* line (`fn name(`) is not a call site; the unsafe gate
  # applies at call sites, so do not flag the declaration of a gated helper.
  is_defn = (l ~ /(^|[^_[:alnum:]])fn[ \t]+[A-Za-z_]/)

  # gated=1: requires unsafe (E_UNSAFE_REQUIRED / contract). gated=0: tracked only.
  cur=l; while (match(cur, /raw[ \t]*\.[ \t]*(load|store)[ \t]*</)) { report("raw_load_store", inside, 1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /mmio[ \t]*\.[ \t]*map[ \t]*</)) { report("mmio_map", inside, 1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /raw[ \t]*\.[ \t]*ptr[ \t]*</)) { report("raw_ptr", inside, 0); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /\.[ \t]*offset[ \t]*\(/)) { report("raw_offset", inside, 1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /forget_unchecked[ \t]*\(/)) { report("forget_unchecked", inside, is_defn?0:1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /arc_get_mut[ \t]*\(/)) { report("arc_get_mut", inside, is_defn?0:1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /(^|[^_[:alnum:]])asm[ \t]+(precise|opaque|volatile)/)) { report("asm", inside, 1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /unchecked[ \t]*\.[ \t]*(add|sub|mul|shl)/)) { report("unchecked_arith", inside, 1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /assume_noalias_unchecked[ \t]*\(/)) { report("assume_noalias", inside, 1); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /bitcast[ \t]*</)) { report("bitcast", inside, 0); cur=substr(cur, RSTART+RLENGTH) }
  cur=l; while (match(cur, /(^|[^_[:alnum:]])uninit([^_[:alnum:]]|$)/)) { report("uninit", inside, 0); cur=substr(cur, RSTART+RLENGTH) }

  to=l; ob=gsub(/[{]/, "&", to); tc=l; cb=gsub(/[}]/, "&", tc)
  if (opens_unsafe && !unsafe_open) { unsafe_min=depth+1; unsafe_open=1 }
  depth += ob - cb
  if (depth < 0) depth=0
  if (unsafe_open && depth < unsafe_min) { unsafe_open=0; unsafe_min=0 }
}

END {
  print  "================ MC unsafe-boundary audit (S0.2) ================"
  printf("scanned %d .mc files under: kernel/ std/\n\n", nfiles)
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
  print "__VIOLATIONS__=" violations > "/dev/stderr"
}
' $FILES 2> "$TMP"

# Surface any VIOLATION lines (awk wrote them to stderr/$TMP).
grep '^VIOLATION' "$TMP" || true
viol=$(grep -o '__VIOLATIONS__=[0-9]*' "$TMP" | head -1 | cut -d= -f2)
viol=${viol:-0}

# Inventory of the FFI / extern surface (declarations, not per-call unsafe ops).
# extern functions are the trust boundary to non-MC code; listed for the audit.
echo
echo "FFI / extern surface (trust boundary, declaration count):"
extern_count=$(grep -rhn '\bextern\b' "${DIRS[@]}" --include='*.mc' | wc -l | tr -d ' ')
printf "  extern declarations       %5s   (FFI boundary; callee correctness is not MC-checked)\n" "${extern_count}"
echo

exit $(( viol > 0 ? 1 : 0 ))
