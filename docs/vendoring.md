# Vendoring and CVE watch

This repository vendors a small number of third-party components under
`third_party/`:

- `quickjs` for confined JavaScript agents.
- `wamr` for confined WebAssembly agents.
- `openlibm` for freestanding libm support used by C apps, QuickJS, and WAMR
  hosts.

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

Every profile-facing TCB component must also be represented in
[`tcb-components.json`](tcb-components.json). For vendored dependencies, that
component row must name the owner, upstream, revision or source evidence,
license, local provenance file, local license file, advisory status, review
date, local modifications, and the profiles that include the component. Profile
manifests may reference only component IDs present in that file.

Kernel-QEMU profile-facing vendored and firmware TCB components must also have a
row in [`tcb-advisory-intake.json`](tcb-advisory-intake.json). That row records
the offline advisory-intake sources to check, retained-subset policy, review
dates, and waiver fields required before a security advisory can be declared not
applicable. This is a deterministic local gate; it does not perform live network
CVE ingestion and does not create a deployable kernel release claim.

Run the static check before sending a vendoring change:

```sh
python3 tools/toolchain/vendoring-test.py
python3 tools/toolchain/tcb-advisory-intake-test.py
zig build vendoring-test
zig build tcb-advisory-intake-test
zig build profile-manifest-test
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
   for WAMR, and `tools/user/build-openlibm.sh` consumers for openlibm.
7. Run the static gates:
   `python3 tools/toolchain/vendoring-test.py`, `zig build vendoring-test`,
   `zig build fast` when practical, and the relevant QEMU gates for the changed
   dependency.
8. Document the update in the dependency README with the new version/commit,
   source checksum, security advisory/CVE review result, local diffs kept, and
   tests run. Update `docs/tcb-components.json` and
   `docs/tcb-advisory-intake.json` in the same patch so the profile TCB view,
   advisory-intake evidence, and vendored-source README cannot drift.

## CVE and advisory watch

For every dependency update and release-readiness pass, check these upstreams:

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
Any not-applicable claim must use the waiver fields listed in
`docs/tcb-advisory-intake.json`; an informal note in a commit message is not
enough release evidence.
