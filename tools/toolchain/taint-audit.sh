#!/usr/bin/env bash
# tools/toolchain/taint-audit.sh — U3: flag untrusted (user-derived) lengths/indices
# used without a bound check.
#
# The bug class: a value that ORIGINATES from user space is untrusted ("tainted"). If
# the kernel uses it as a length, index, copy-size, or loop bound BEFORE validating it
# against a kernel-chosen limit, an attacker chooses that bound — the heartbleed shape
# (trust a user-supplied length -> over-read past the buffer, CVE-2014-0160).
#
# The structural defense lives in kernel/core/uaccess.mc: `Tainted<T>` carries an
# untrusted scalar and exposes NO raw accessor; the only way to extract a usable value
# is through `checked_len` / `checked_index` / `validate_bound`, which reject anything
# outside the limit (fail closed). This script is the independent auditor of that
# discipline. It scans kernel/ and, per function, marks every name that is DERIVED from
# a user fetch as tainted, then flags a tainted name used as a length/index/loop-bound
# that was not first passed through a validator.
#
# A name becomes TAINTED in a function when it is bound from:
#   - `... = snap.value`            (the raw value read out of a UserSnapshot)
#   - `... = SOMETHING.value` where SOMETHING was bound from an `ok(SNAP)` arm of a
#     fetch_user{,_pt} switch (the snapshot binding)
#   - `... = <user-read-call>` directly, where the call is copy_from_user{,_pt} /
#     fetch_user{,_pt} and the LHS is then used numerically
#   - `let X = <expr mentioning a tainted name>` (taint propagates through assignment)
#
# A tainted name is CLEANSED for the rest of the function once it appears as an argument
# to `checked_len` / `checked_index` / `validate_bound` (the value it yields via the
# `ok(...)` arm is trusted; the validator is the only sanctioned untaint).
#
# A tainted name is FLAGGED when, while still tainted, it is used as:
#   - the LENGTH argument (4th arg) of copy_from_user{,_pt} / copy_to_user{,_pt}
#   - an array/pointer SUBSCRIPT:  NAME[...]  or  ...[NAME]
#   - a LOOP BOUND in a `while` comparison:  while NAME < / <= / > / >= ...  (or RHS)
#
# It is a *lint*, not the compiler: it parses with awk (per-function scope, brace
# tracking, comment/string stripping) and keys on textual names. It is deliberately
# conservative:
#   - False positives: a name that happens to share a tainted name's spelling but was
#     re-bound to a trusted value via a path the lint does not model; or a `.value`
#     read off a non-user struct named like a snapshot. The fix is to route the value
#     through a validator (which also cleanses it here).
#   - False negatives: taint laundered through a helper function call, arithmetic into a
#     differently-spelled temporary, or a fetch+use split across files. Catching those
#     needs taint typing through sema (a noted follow-up). The `Tainted<T>` wrapper
#     makes the common case structural; this lint is the greppable backstop.
#
# Exit non-zero if a likely unvalidated tainted use is found (a real finding — a WIN to
# surface), else print the inventory and exit 0 (the current kernel is clean).
#
# Usage: taint-audit.sh [DIR ...]            (default: kernel)
#        taint-audit.sh --self-test          (run the built-in negative test)

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
  # A deliberately unvalidated tainted-length use: snapshot a user length, read its
  # raw `.value`, and feed it straight to a copy as the length — never bound-checked.
  # An attacker who supplies a huge length drives an over-read. The audit MUST flag it.
  SELF_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELF_TMP"' EXIT
  mkdir -p "$SELF_TMP/kernel/core"
  cat > "$SELF_TMP/kernel/core/taint_bad.mc" <<'MC'
import "kernel/core/uaccess.mc";
import "std/addr.mc";

// NEGATIVE TEST (must be flagged): a textbook unvalidated tainted length. `n` is the
// raw user-supplied length read out of a snapshot; it is fed directly to a copy as the
// length WITHOUT passing checked_len/validate_bound — the heartbleed over-read.
export fn bad_unvalidated_len(us: *UserSpace, lenp: UserPtr<u8>, dst: PAddr, src: UserPtr<u8>) -> bool {
    var n: u8 = 0;
    switch fetch_user(u8, us, lenp) {
        ok(snap) => { n = snap.value; }   // tainted: raw user length
        err(e) => { return false; }
    }
    // BUG: `n` drives the copy length with no bound check.
    switch copy_from_user(us, dst, src, n) {
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
  echo "taint-audit: no .mc files under: ${DIRS[*]}" >&2
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

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Top-level (depth-0) nth comma-separated arg of a call-argument string.
function nth_arg(args, k,   i, c, depth, cur, idx) {
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

# Capture the argument list of the FIRST occurrence of one of the named calls on a
# (stripped) line. Returns "" if the call is absent or spans lines (conservative skip).
function call_args(l, re,   rest, depth, i, c, end, args) {
  if (!match(l, re)) return "<<NONE>>"   # marker: no such call
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

# Does the (stripped) line mention bareword NAME (token boundary)?
function mentions(l, name,   re) {
  re = "(^|[^A-Za-z0-9_])" name "([^A-Za-z0-9_]|$)"
  return (l ~ re)
}

BEGIN { nfiles=0; nfetch=0; findings=0; depth=0; infn=0; fnname=""; fnopen=0 }

FNR==1 { nfiles++; depth=0; infn=0; fnname=""; delete tainted; delete tline; snapvar="" }

{
  l = strip($0)

  # ---- function scope ----
  if (!infn && depth==0 && match(l, /(^|[^_[:alnum:]])fn[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
    nm = substr(l, RSTART, RLENGTH); sub(/^.*fn[ \t]+/, "", nm)
    fnname = nm; infn=1; fnopen=depth
    delete tainted; delete tline; snapvar=""
  }

  if (infn) {
    # ---- CLEANSE: any tainted name passed to a validator is trusted hereafter ----
    a = call_args(l, "(checked_len|checked_index|validate_bound)[ \t]*\\(")
    if (a != "<<NONE>>") {
      for (nmx in tainted) {
        if (mentions(a, nmx)) { delete tainted[nmx]; delete tline[nmx] }
      }
    }

    # ---- record the snapshot binding name from an `ok(SNAP)` arm of a user fetch ----
    # We treat the most recent `ok(NAME) =>` after a fetch_user line as the snapshot var.
    if (match(l, /ok[ \t]*\([ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\)[ \t]*=>/)) {
      s = l; sub(/^.*ok[ \t]*\([ \t]*/, "", s); sub(/[ \t]*\).*$/, "", s)
      if (sawfetch) { snapvar = s; sawfetch = 0 }
    }

    # ---- TAINT SOURCES ----
    # A direct user-read call bound to an LHS via `= call(...)` taints the LHS.
    if (match(l, /(^|[ \t])(var|let)[ \t]+[A-Za-z_][A-Za-z0-9_]*/) && \
        l ~ /(copy_from_user|copy_from_user_pt|fetch_user|fetch_user_pt)[ \t]*\(/ && \
        l ~ /=/) {
      lhs = l; sub(/^.*(var|let)[ \t]+/, "", lhs); sub(/[ \t:=].*$/, "", lhs)
      if (lhs != "") { tainted[lhs]=1; tline[lhs]=FNR }
    }

    # `X = <SNAP>.value` (raw read out of a user snapshot) taints X. Matches both
    # `var X: T = snap.value` and a plain `X = snap.value` re-assignment, anywhere on
    # the line (a one-line `ok(snap) => { i = snap.value; }` arm included). We match the
    # `IDENT = IDENT.value` shape directly so multiple `=>` arrows on the line cannot
    # confuse the LHS. The snapshot base must be the tracked `snapvar` or spelled like a
    # snapshot (`snap*`). Bare `=` only — not `==`/`<=`/`>=`/`=>`.
    if (match(l, /[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*[A-Za-z_][A-Za-z0-9_]*\.value([^A-Za-z0-9_]|$)/)) {
      seg = substr(l, RSTART, RLENGTH)
      lhs = seg; sub(/[ \t]*=.*$/, "", lhs); gsub(/[ \t]/, "", lhs)
      base = seg; sub(/^.*=[ \t]*/, "", base); sub(/\.value.*$/, "", base); gsub(/[ \t]/, "", base)
      ch = substr(l, RSTART-1, 1)              # char just before the LHS ident
      if (base != "" && (base == snapvar || base ~ /snap/) && ch !~ /[<>=!]/) {
        if (lhs ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { tainted[lhs]=1; tline[lhs]=FNR }
      }
    }

    # taint PROPAGATION: `let/var X = <expr mentioning a tainted name>` taints X.
    if (l ~ /(^|[ \t])(var|let)[ \t]+[A-Za-z_][A-Za-z0-9_]*/ && l ~ /=/) {
      rhs = l; sub(/^.*=[ \t]*/, "", rhs)
      lhs = l; sub(/=.*$/, "", lhs); sub(/^.*(var|let)[ \t]+/, "", lhs)
      gsub(/[ \t]/, "", lhs); sub(/:.*$/, "", lhs)
      for (nmx in tainted) {
        if (nmx != lhs && mentions(rhs, nmx)) { tainted[lhs]=1; tline[lhs]=FNR }
      }
    }

    # ---- SINKS: a tainted name used as length / index / loop-bound ----
    # (1) length arg (4th) of a copy_*_user call
    ca = call_args(l, "(copy_from_user_pt|copy_from_user|copy_to_user_pt|copy_to_user)[ \t]*\\(")
    if (ca != "<<NONE>>") {
      lenarg = nth_arg(ca, 4)
      for (nmx in tainted) {
        if (mentions(lenarg, nmx)) {
          findings++
          printf("TAINT  %s:%d  fn `%s` uses user-derived `%s` (tainted at line %d) as a copy LENGTH without checked_len/validate_bound\n",
                 FILENAME, FNR, fnname, nmx, tline[nmx]) > "/dev/stderr"
          delete tainted[nmx]; delete tline[nmx]   # report once
        }
      }
    }

    # (2) subscript: NAME[ ... ]  or  ...[ NAME ]
    for (nmx in tainted) {
      sub_re_lhs = "(^|[^A-Za-z0-9_])" nmx "[ \t]*\\["          # tainted as the base (rare)
      sub_re_idx = "\\[[ \t]*" nmx "([ \t]*\\]|[^A-Za-z0-9_])"  # tainted as the index
      if (l ~ sub_re_idx) {
        findings++
        printf("TAINT  %s:%d  fn `%s` uses user-derived `%s` (tainted at line %d) as an array INDEX without checked_index/validate_bound\n",
               FILENAME, FNR, fnname, nmx, tline[nmx]) > "/dev/stderr"
        delete tainted[nmx]; delete tline[nmx]
      }
    }

    # (3) loop bound: `while ... NAME (< <= > >=) ...` or `... (< <= > >=) NAME`
    if (l ~ /(^|[^A-Za-z0-9_])while([^A-Za-z0-9_]|$)/) {
      for (nmx in tainted) {
        cmp_l = "(^|[^A-Za-z0-9_])" nmx "[ \t]*(<|<=|>|>=)"
        cmp_r = "(<|<=|>|>=)[ \t]*" nmx "([^A-Za-z0-9_]|$)"
        if (l ~ cmp_l || l ~ cmp_r) {
          findings++
          printf("TAINT  %s:%d  fn `%s` uses user-derived `%s` (tainted at line %d) as a LOOP BOUND without checked_len/validate_bound\n",
                 FILENAME, FNR, fnname, nmx, tline[nmx]) > "/dev/stderr"
          delete tainted[nmx]; delete tline[nmx]
        }
      }
    }

    # mark that a fetch was seen on this line (so the NEXT ok(...) arm names the snapshot)
    if (l ~ /(fetch_user|fetch_user_pt)[ \t]*\(/) { sawfetch=1; nfetch++ }
    else if (l ~ /(copy_from_user|copy_from_user_pt)[ \t]*\(/) { nfetch++ }
  }

  # ---- brace bookkeeping ----
  to=l; ob=gsub(/[{]/, "&", to); tc=l; cb=gsub(/[}]/, "&", tc)
  depth += ob - cb
  if (depth < 0) depth=0
  if (infn && depth <= fnopen) { infn=0; fnname=""; delete tainted; delete tline; snapvar=""; sawfetch=0 }
}

END {
  print  "============== MC tainted length/index audit (U3) =============="
  printf("scanned %d .mc file(s); %d user-read site(s) (copy_from_user{,_pt} / fetch_user{,_pt})\n\n", nfiles, nfetch)
  if (findings==0)
    print "RESULT: clean — no user-derived value reaches a length/index/loop-bound without a validator."
  else
    printf("RESULT: %d unvalidated tainted use(s) found (see TAINT lines on stderr).\n", findings)
  print  "================================================================"
  print "__FINDINGS__=" findings > "/dev/stderr"
}
' $FILES 2> "$TMP"

grep '^TAINT' "$TMP" >&2 || true
f=$(grep -o '__FINDINGS__=[0-9]*' "$TMP" | head -1 | cut -d= -f2)
f=${f:-0}

exit $(( f > 0 ? 1 : 0 ))
