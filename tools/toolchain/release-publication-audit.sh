#!/usr/bin/env bash
# Read-only GitHub release-publication evidence audit.
#
# This script intentionally performs only GET/list operations through gh. It does
# not create branch protection, dispatch workflows, create releases, upload
# assets, or mutate repository state.

set -uo pipefail

REPO="${MC_RELEASE_AUDIT_REPO:-Haofei/modern-c}"
BRANCH="${MC_RELEASE_AUDIT_BRANCH:-master}"
WORKFLOW="${MC_RELEASE_AUDIT_WORKFLOW:-release.yml}"
LIMIT="${MC_RELEASE_AUDIT_LIMIT:-10}"

failures=0
pending=0

pass() {
  printf 'PASS: %s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*"
  failures=$((failures + 1))
}

pending_evidence() {
  printf 'PENDING: %s\n' "$*"
  pending=$((pending + 1))
}

note() {
  printf 'NOTE: %s\n' "$*"
}

run_gh() {
  local out_file="$1"
  local err_file="$2"
  shift 2
  gh "$@" >"$out_file" 2>"$err_file"
}

if ! command -v gh >/dev/null 2>&1; then
  fail "GitHub CLI 'gh' is required to audit external publication controls."
  note "Install gh and authenticate with read access to ${REPO}, then rerun this script."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required to parse GitHub CLI JSON output."
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

note "auditing repo=${REPO} branch=${BRANCH} workflow=${WORKFLOW} limit=${LIMIT}"

branch_out="$tmpdir/branch-protection.json"
branch_err="$tmpdir/branch-protection.err"
if run_gh "$branch_out" "$branch_err" api --method GET "repos/${REPO}/branches/${BRANCH}/protection"; then
  pass "branch protection is enabled for ${REPO}@${BRANCH}."
else
  rc=$?
  if grep -q 'HTTP 404' "$branch_err"; then
    fail "branch protection is missing for ${REPO}@${BRANCH} (GitHub API returned HTTP 404)."
    note "Protect ${BRANCH} before public release publication, then rerun this audit."
  else
    fail "could not verify branch protection for ${REPO}@${BRANCH} (gh exit ${rc})."
    sed 's/^/  gh: /' "$branch_err"
  fi
fi

runs_out="$tmpdir/release-runs.json"
runs_err="$tmpdir/release-runs.err"
if run_gh "$runs_out" "$runs_err" run list \
  --repo "$REPO" \
  --workflow "$WORKFLOW" \
  --limit "$LIMIT" \
  --json databaseId,status,conclusion,createdAt,event,headBranch,url \
  --jq '.'
then
  if ! run_count="$(python3 - "$runs_out" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))))
PY
  )"; then
    fail "could not parse ${WORKFLOW} workflow-run JSON from gh."
    run_count=""
  fi
  if ! success_count="$(python3 - "$runs_out" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1], encoding="utf-8"))
print(sum(1 for run in runs if run.get("status") == "completed" and run.get("conclusion") == "success"))
PY
  )"; then
    fail "could not parse successful ${WORKFLOW} workflow-run evidence from gh."
    success_count=0
  fi
  if [ -n "$run_count" ] && [ "$run_count" = "0" ]; then
    pending_evidence "no recent ${WORKFLOW} workflow runs were found for ${REPO}."
    note "Run a manual dry run, or inspect a tag-triggered release run, before claiming external workflow evidence."
  elif [ "${success_count:-0}" -gt 0 ]; then
    if ! latest_success="$(python3 - "$runs_out" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1], encoding="utf-8"))
for run in runs:
    if run.get("status") == "completed" and run.get("conclusion") == "success":
        print(
            f"run_id={run.get('databaseId')} created_at={run.get('createdAt')} "
            f"event={run.get('event')} branch={run.get('headBranch')} url={run.get('url')}"
        )
        break
PY
    )"; then
      fail "could not render successful ${WORKFLOW} workflow-run evidence from gh."
    else
      pass "found successful ${WORKFLOW} workflow evidence: ${latest_success}"
    fi
  elif [ -n "$run_count" ]; then
    pending_evidence "found ${run_count} recent ${WORKFLOW} workflow run(s), but none completed successfully."
    if ! python3 - "$runs_out" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1], encoding="utf-8"))
for run in runs:
    print(
        f"  run_id={run.get('databaseId')} status={run.get('status')} "
        f"conclusion={run.get('conclusion')} created_at={run.get('createdAt')} url={run.get('url')}"
    )
PY
    then
      fail "could not render ${WORKFLOW} workflow-run evidence from gh."
    fi
  fi
else
  rc=$?
  fail "could not list ${WORKFLOW} workflow runs for ${REPO} (gh exit ${rc})."
  sed 's/^/  gh: /' "$runs_err"
fi

releases_out="$tmpdir/releases.json"
releases_err="$tmpdir/releases.err"
if run_gh "$releases_out" "$releases_err" release list \
  --repo "$REPO" \
  --limit "$LIMIT" \
  --json tagName,name,isDraft,isPrerelease,publishedAt \
  --jq '.'
then
  if ! release_count="$(python3 - "$releases_out" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))))
PY
  )"; then
    fail "could not parse GitHub Release JSON from gh."
    release_count=""
  fi
  if ! public_release_count="$(python3 - "$releases_out" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1], encoding="utf-8"))
print(sum(1 for release in releases if not release.get("isDraft") and release.get("publishedAt")))
PY
  )"; then
    fail "could not parse published GitHub Release evidence from gh."
    public_release_count=0
  fi
  if [ -n "$release_count" ] && [ "$release_count" = "0" ]; then
    pending_evidence "no GitHub Releases were found for ${REPO}."
    note "Publish a release only after the release checklist is satisfied, then rerun this audit."
  elif [ "${public_release_count:-0}" -gt 0 ]; then
    if ! latest_release="$(python3 - "$releases_out" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1], encoding="utf-8"))
for release in releases:
    if not release.get("isDraft") and release.get("publishedAt"):
        print(
          f"tag={release.get('tagName')} name={release.get('name')} "
          f"prerelease={release.get('isPrerelease')} published_at={release.get('publishedAt')} "
        )
        break
PY
    )"; then
      fail "could not render published GitHub Release evidence from gh."
    else
      pass "found published GitHub Release evidence: ${latest_release}"
    fi
  elif [ -n "$release_count" ]; then
    pending_evidence "found ${release_count} release record(s), but none are published non-draft releases."
    if ! python3 - "$releases_out" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1], encoding="utf-8"))
for release in releases:
    print(
        f"  tag={release.get('tagName')} draft={release.get('isDraft')} "
        f"prerelease={release.get('isPrerelease')} published_at={release.get('publishedAt')} "
    )
PY
    then
      fail "could not render GitHub Release evidence from gh."
    fi
  fi
else
  rc=$?
  fail "could not list GitHub Releases for ${REPO} (gh exit ${rc})."
  sed 's/^/  gh: /' "$releases_err"
fi

if [ "$failures" -eq 0 ] && [ "$pending" -eq 0 ]; then
  pass "release publication controls have reproducible external evidence."
  exit 0
fi

printf 'SUMMARY: %d fail(s), %d pending evidence item(s).\n' "$failures" "$pending"
exit 1
