#!/usr/bin/env bash
# tools/toolchain/double-fetch-audit.sh — U2: flag double-fetch / TOCTOU on user memory.
#
# The double-fetch (TOCTOU) bug class: the kernel copies a datum in from a user
# pointer, validates it, then copies the SAME user pointer in a SECOND time to use
# it — and a racing thread / mapping changed the bytes between the two reads, so the
# value validated is not the value used ("validate, then it changes under you", the
# classic CVE family, e.g. CVE-2016-6516).
#
# The structural defense lives in kernel/core/uaccess.mc: `fetch_user` /
# `fetch_user_pt` copy a user datum in EXACTLY ONCE into an immutable
# `UserSnapshot<T>`; reading `.value` twice is free and race-free, so a second fetch
# of the same datum is unnecessary. This script is the independent auditor of that
# discipline: it scans kernel/ for any function that copies the SAME `UserPtr`
# expression in MORE THAN ONCE.
#
# It is a *lint*, not the compiler: it parses with awk (per-function scope, brace
# tracking, comment/string stripping) and keys on the textual user-source argument
# of each user-read call. It is deliberately conservative:
#   - It flags `copy_from_user{,_pt}(.., SRC, ..)` and `fetch_user{,_pt}(T, .., SRC)`
#     when the SAME `SRC` text appears as the user source in two+ calls in one fn.
#   - False positives: a fn that legitimately re-reads two genuinely independent
#     data through a syntactically identical source expression (rare; the fix is to
#     snapshot once). A loop that re-fetches is also flagged — usually a real smell.
#   - False negatives: two reads of the same datum spelled via DIFFERENT expressions
#     (e.g. `p` vs `p + 0`), or split across helper functions. Catching those needs
#     the sema layer; this lint is the greppable first cut. See docs/uaccess.md.
#
# Exit non-zero if a likely double-fetch is found (a real finding — a WIN to surface),
# else print the per-call inventory and exit 0 (the current kernel is clean: every
# user datum is copied in once).
#
# Usage: double-fetch-audit.sh [DIR ...]            (default: kernel)
#        double-fetch-audit.sh --self-test          (run the built-in negative test)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

self_test=0
DIRS=()
for a in "$@"; do
  case "$a" in
    --self-test) self_test=1 ;;
    *) DIRS+=("$a") ;;
  esac
done
[ ${#DIRS[@]} -eq 0 ] && DIRS=(kernel)

SELF_TMP=""
if [ "$self_test" = 1 ]; then
  # A deliberately double-fetching snippet: read a length from the SAME UserPtr
  # twice — validate the first read, then re-read to use it. An attacker who flips
  # the bytes between the two reads defeats the check. The audit MUST flag this.
  SELF_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELF_TMP"' EXIT
  mkdir -p "$SELF_TMP/kernel/core"
  cat > "$SELF_TMP/kernel/core/double_fetch_bad.mc" <<'MC'
import "kernel/core/uaccess.mc";
import "std/addr.mc";

// NEGATIVE TEST (must be flagged): a textbook double-fetch. `lenp` is copied in
// once to validate the length, then copied in AGAIN to actually use it — the
// second read can observe attacker-mutated bytes the first read validated.
export fn bad_double_fetch(us: *UserSpace, lenp: UserPtr<u8>, kbuf: PAddr) -> bool {
    var n1: PAddr = kbuf;
    switch copy_from_user(us, n1, lenp, 4) {   // FETCH #1: validate
        ok(v) => {}
        err(e) => { return false; }
    }
    // ... bounds-check n1 here ...
    var n2: PAddr = kbuf;
    switch copy_from_user(us, n2, lenp, 4) {   // FETCH #2 of the SAME lenp: TOCTOU
        ok(v) => {}
        err(e) => { return false; }
    }
    return true;
}
MC
  DIRS=("$SELF_TMP/kernel")
fi

FILES=$(find "${DIRS[@]}" -name '*.mc' 2>/dev/null | sort)
if [ -z "$FILES" ]; then
  echo "double-fetch-audit: no .mc files under: ${DIRS[*]}" >&2
  exit 0
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"; [ -n "$SELF_TMP" ] && rm -rf "$SELF_TMP"' EXIT

awk '
# Strip // comments and string/char literal contents.
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

# Trim surrounding whitespace.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# The user-source argument of a user-read call:
#   copy_from_user(us, dst, SRC, len)         -> 3rd arg
#   copy_from_user_pt(uas, dst, SRC, len)     -> 3rd arg
#   fetch_user(T, us, SRC)                     -> 3rd arg
#   fetch_user_pt(T, uas, SRC)                 -> 3rd arg
# In every audited form the user pointer is the 3rd comma-separated argument. We
# split the call arguments at top-level commas (depth 0) and take arg #3.
function nth_arg(args, k,   i, c, depth, cur, idx, out) {
  depth=0; idx=1; cur=""
  for (i=1; i<=length(args); i++) {
    c=substr(args,i,1)
    if (c=="(" || c=="[" || c=="<") depth++
    else if (c==")" || c=="]" || c==">") depth--
    else if (c=="," && depth==0) { if (idx==k) return trim(cur); idx++; cur=""; continue }
    cur=cur c
  }
  if (idx==k) return trim(cur)
  return ""
}

# Pull the user source from a user-read call on a (stripped) line. Returns "" if none.
function user_src(l,   m, rest, args, depth, i, c, end) {
  if (match(l, /(copy_from_user_pt|copy_from_user|fetch_user_pt|fetch_user)[ \t]*\(/)) {
    rest = substr(l, RSTART+RLENGTH)        # text after the opening (
    # capture up to the matching ) at depth 0
    depth=0; end=0; args=""
    for (i=1; i<=length(rest); i++) {
      c=substr(rest,i,1)
      if (c=="(") depth++
      else if (c==")") { if (depth==0) { end=1; break } depth-- }
      args=args c
    }
    if (!end) return ""                     # call spans lines; conservative skip
    return nth_arg(args, 3)
  }
  return ""
}

BEGIN { nfiles=0; ncalls=0; findings=0; depth=0; infn=0; fnname=""; fnline=0 }

FNR==1 { nfiles++; depth=0; infn=0; fnname="" }

{
  l = strip($0)

  # Track function scope: an `fn NAME(` at brace-depth 0 starts a function; its body
  # ends when depth returns to the function-open level. We collect user sources seen
  # within one function and flag any source spelled twice.
  if (!infn && depth==0 && match(l, /(^|[^_[:alnum:]])fn[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
    nm = substr(l, RSTART, RLENGTH); sub(/^.*fn[ \t]+/, "", nm)
    fnname = nm; fnline = FNR; infn=1; fnopen=depth
    delete seen; delete seenline
  }

  src = user_src(l)
  if (src != "" && infn) {
    ncalls++
    if (src in seen) {
      findings++
      printf("DOUBLE-FETCH  %s:%d  fn `%s` re-reads the same UserPtr `%s` (first at line %d) — copy it in once via fetch_user/UserSnapshot\n",
             FILENAME, FNR, fnname, src, seenline[src]) > "/dev/stderr"
    } else {
      seen[src]=1; seenline[src]=FNR
    }
  } else if (src != "") {
    ncalls++   # a user read outside any fn scope (e.g. top-level); count, do not pair
  }

  # brace bookkeeping (after the line is processed)
  to=l; ob=gsub(/[{]/, "&", to); tc=l; cb=gsub(/[}]/, "&", tc)
  depth += ob - cb
  if (depth < 0) depth=0
  if (infn && depth <= fnopen) { infn=0; fnname=""; delete seen; delete seenline }
}

END {
  print  "============== MC double-fetch / TOCTOU audit (U2) =============="
  printf("scanned %d .mc file(s); %d user-read call site(s) (copy_from_user{,_pt} / fetch_user{,_pt})\n\n", nfiles, ncalls)
  if (findings==0)
    print "RESULT: clean — no function copies the same UserPtr in more than once."
  else
    printf("RESULT: %d likely double-fetch(es) found (see DOUBLE-FETCH lines on stderr).\n", findings)
  print  "================================================================"
  print "__FINDINGS__=" findings > "/dev/stderr"
}
' $FILES 2> "$TMP"

grep '^DOUBLE-FETCH' "$TMP" >&2 || true
f=$(grep -o '__FINDINGS__=[0-9]*' "$TMP" | head -1 | cut -d= -f2)
f=${f:-0}

exit $(( f > 0 ? 1 : 0 ))
