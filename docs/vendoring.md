# Vendoring and CVE watch

This repository vendors a small number of third-party components under
`third_party/`:

- `bearssl` for freestanding TLS/crypto support.
- `quickjs` for confined JavaScript agents.
- `wamr` for confined WebAssembly agents.
- `openlibm` for freestanding libm support used by C apps, QuickJS, and WAMR
  hosts.

Generated trust-anchor material under `third_party/trust-anchors/` is documented
separately in that directory and is refreshed from certificates rather than from
an upstream source tree.

## Required metadata

Every vendored dependency must have `third_party/<name>/README.vendored.md`
with:

- Upstream URL.
- Recorded version, commit, tag, or source evidence available in the tree. If an
  exact commit is unknown, the README must say so explicitly and name the next
  update action needed to recover precise provenance.
- License path.
- What is kept and what is dropped from upstream.
- Local modifications, including local platform ports or build-only adaptations.
- How the dependency is built and used here.

Every license-bearing dependency must also be represented in
`THIRD-PARTY-LICENSES.md`, and that manifest must link both the dependency's
`README.vendored.md` provenance record and its retained license file.

Run the static check before sending a vendoring change:

```sh
python3 tools/toolchain/vendoring-test.py
zig build vendoring-test
```

## Re-vendor process

1. Identify the current local version from `README.vendored.md` and from source
   evidence in the tree, such as `quickjs.h`, `core/version.h`, or upstream
   license/source headers.
2. Fetch upstream in a temporary directory outside the checkout. Prefer an
   immutable tag or commit over a branch head. Record the tag/commit and an
   archive checksum in the dependency README.
3. Check upstream release notes, changelogs, GitHub Security Advisories, CVE
   databases, and distro/security tracker references for the old and new
   versions. Record whether the update is security-driven.
4. Replace only the intended vendored subset. Preserve required license files.
   Do not import upstream tests, examples, docs, generated build trees, or unused
   engines unless the local build needs them.
5. Diff the old and new vendor trees. Separate upstream changes from local
   modifications such as WAMR's `mc` platform port. Reapply local changes
   deliberately and update the local-modifications section.
6. Re-run the component gates:
   `tools/user/build-qjs.sh` consumers for QuickJS, WAMR confined-agent gates
   for WAMR, `tools/user/build-openlibm.sh` consumers for openlibm, and
   `tools/tls/bearssl-smoke-test.sh` or related TLS gates for BearSSL.
7. Run the static gates:
   `python3 tools/toolchain/vendoring-test.py`, `zig build vendoring-test`,
   `zig build fast` when practical, and the relevant QEMU gates for the changed
   dependency.
8. Document the update in the dependency README with the new version/commit,
   source checksum, security advisory/CVE review result, local diffs kept, and
   tests run.

## CVE and advisory watch

For every dependency update and release-readiness pass, check these upstreams:

- BearSSL: upstream BearSSL site/repository, project announcements, CVE search
  for `BearSSL`, and distro security trackers.
- QuickJS-NG: GitHub releases/issues/security advisories for
  `quickjs-ng/quickjs`, CVE search for `QuickJS` and `QuickJS-NG`, and relevant
  distro security trackers.
- WAMR: GitHub releases/issues/security advisories for
  `bytecodealliance/wasm-micro-runtime`, CVE search for `WAMR` and
  `wasm-micro-runtime`, and Bytecode Alliance security communications.
- openlibm: GitHub releases/issues for `JuliaMath/openlibm`, CVE search for
  `openlibm`, and distro security trackers.

Security fixes should be treated as release blockers until either re-vendored or
documented as not applicable to the retained subset and local build flags.
