# Release Process

Status: draft release process with an implemented Linux and macOS artifact
workflow. Release publication is still conservative: the workflow builds
tarballs, checksums, a release inventory, a CycloneDX SBOM, and GitHub
artifact attestations. No public stable release has been cut yet.

## Version Identity

The development version is `0.7.0-dev`.

- `build.zig.zon` records the package version and minimum Zig version.
- `.zigversion` pins the local/CI Zig toolchain.
- `zig build -Dversion=<version>` controls the string reported by `mcc --version`.
- Without `-Dversion`, local builds report `mcc 0.7.0-dev`.
- Release tags use the `v<version>` form. The release workflow strips the leading
  `v` and passes `-Dversion=<version>` to Zig.
- Manual dispatch may package `0.7.0-dev` for dry-run artifact inspection, but
  tag-triggered publication rejects development versions containing `-dev`.
- Every workflow release version must exactly match `build.zig.zon`; cutting a
  stable tag therefore requires committing the stable source version first.

## Release Checklist

Before tagging a release:

1. Choose the release version and build with `zig build -Dversion=<version> install`.
2. Confirm `SECURITY.md`, `STABILITY.md`, and `CHANGELOG.md` describe the support
   window and compatibility surfaces for that exact tag. Private vulnerability
   reports use GitHub Security Advisories with coordinated embargo/disclosure.
3. Run `zig build m0` on Ubuntu 24.04 with LLVM 18 (`MC_LLVM_MAJOR=18`) and no skips.
4. Run `zig build m0` in the pinned Linux container with no skips.
5. Confirm the nightly rotating-seed mcfuzz workflow is green for the release
   candidate commit. Shrink any reported failing seed with `tools/fuzz/mcfuzz.py
   shrink` and commit the minimized repro under `tools/fuzz/corpus/` before
   tagging.
6. Confirm the nightly QEMU benchmark workflow is green for the release candidate
   commit. Its committed baseline lives in `tools/bench/nightly-baseline.tsv`; update
   the TSV only when a deliberate performance change is measured on the pinned
   Ubuntu 24.04 / Zig 0.16.0 / LLVM 18 toolchain.
7. Run `zig build fast` on every supported host tier.
8. For generated C or `.mcmap` artifacts kept for release audit, invoke `mcc
   emit-c` / `mcc emit-map` with `--remap-prefix=<build-root>=<logical-root>`
   so `#line` directives and source-map `source_path` metadata do not record
   host-specific temporary paths.
9. Run a manual dry run of `.github/workflows/release.yml` for the candidate
   version. The workflow builds with Zig 0.16.0, `-Doptimize=ReleaseSafe`, and
   `-Dversion=<version>` via `tools/ci/package-release.py`. The release workflow
   verifies `GITHUB_SHA` and the source version, runs `zig build preflight`, the
   focused `release-metadata-test`, `package-release-test`, and
   `release-safe-install-test` gates, and a complete no-skip
   `MC_REQUIRE_TOOLS=1 zig build m0` before building artifacts. It also runs the built compiler and checks its
   reported version, then requires a clean source tree, so the publishing path proves
   the exact source revision passed the documented qualification bar.
10. Confirm the dry-run workflow artifact contains tarballs for
   `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos`, and
   `aarch64-macos`.
   Each tarball must contain `bin/mcc`, `bin/mcc-real`, `std/`,
   `tools/toolchain/mcc-build.sh`, `tools/toolchain/mcc-cc.sh`,
   `tools/toolchain/mcc-llvm-cc.sh`, `README.md`, `LICENSE`, `SECURITY.md`,
   `STABILITY.md`, `CHANGELOG.md`, and `THIRD-PARTY-LICENSES.md`.
11. Confirm `SHA256SUMS`, `mcc-<version>-release-inventory.json`, and
   `mcc-<version>-sbom.cdx.json` are present and that
   `sha256sum -c SHA256SUMS` passes.
12. Confirm the workflow generated Sigstore-backed artifact attestations with
   `actions/attest` using `subject-checksums: zig-out/release/SHA256SUMS`.
13. Tag the exact commit and record the tag in `CHANGELOG.md`. Pushing `v*`
   creates one GitHub Release with immutable assets. Publication fails if that
   release already exists; `gh release upload` never uses replacement mode, and
   replacing an asset requires a new version and tag.

## Release Artifacts

`.github/workflows/release.yml` runs on `v*` tags and manual dispatch. Manual
dispatch defaults to a dry run, which uploads workflow artifacts without creating
a GitHub Release. A tag run publishes the same artifact set to the GitHub Release
for that tag. Both dry-run and tag runs generate GitHub artifact attestations for
the files named by `SHA256SUMS`.

The packaging helper is intentionally local-testable:

```sh
python3 tools/ci/package-release.py release --version 0.7.0 \
  --targets x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos
```

The helper builds `mcc` with `zig build -Dtarget=<target> -Doptimize=ReleaseSafe
-Dversion=<version> install`, stages the required runtime files, writes a
deterministic tarball, emits release inventory and CycloneDX SBOM JSON files, and
writes `SHA256SUMS`.

The release workflow stages the VS Code extension into `zig-out/release`, appends
it to `SHA256SUMS`, verifies that every checksum subject is a file in that
directory, and then invokes `actions/attest` with `subject-checksums:
zig-out/release/SHA256SUMS`. The attestation is signed with the workflow's GitHub
OIDC identity and stored by GitHub's artifact attestation service.

To verify a downloaded release asset, first check the digest manifest from the
release directory:

```sh
sha256sum -c SHA256SUMS
```

Then verify the artifact attestation for each downloaded tarball, VSIX, inventory,
or SBOM file named by the manifest:

```sh
gh attestation verify --owner <owner> mcc-0.7.0-x86_64-linux-musl.tar.gz
```

For repository-scoped checks, use the repository owner that published the release.
The attestation confirms the artifact digest and the GitHub Actions provenance;
the CycloneDX SBOM remains the component inventory for dependency and license
review.

## Complete Source Package

`build.zig.zon` includes the compiler, tests, self-host sources, vendored source
and licenses, editor integration, workflows, and release metadata needed by the
qualification surface. `zig build source-package-test` invokes `zig fetch` to
materialize that exact `.paths` selection into a fresh directory without `.git`,
then runs `zig build test` and `zig build release-metadata-test` there. This keeps
the Zig source package and the repository checkout from becoming two different
qualification inputs.

The current target set is:

- `x86_64-linux-musl`
- `aarch64-linux-musl`
- `x86_64-macos`
- `aarch64-macos`

## Publication Controls Audit

External publication-control evidence is audited with:

```sh
bash tools/toolchain/release-publication-audit.sh
```

The audit is read-only and uses `gh` list/API calls only. It verifies:

- branch protection for the target branch;
- an active `Protect release tags` ruleset for immutable `v*` tags;
- enabled GitHub Private Vulnerability Reporting;
- recent `release.yml` workflow-run evidence;
- existing GitHub Release publication evidence.

By default it audits `Haofei/modern-c`, branch `master`, workflow `release.yml`.
Override those targets when auditing a fork or renamed workflow:

```sh
MC_RELEASE_AUDIT_REPO=owner/repo \
MC_RELEASE_AUDIT_BRANCH=main \
MC_RELEASE_AUDIT_WORKFLOW=release.yml \
bash tools/toolchain/release-publication-audit.sh
```

The script prints `PASS`, `FAIL`, and `PENDING` lines and exits nonzero unless
every external evidence check is present. A nonzero result is expected before the
repository has branch protection, successful release workflow evidence, and a
published GitHub Release. It does not enable protection, dispatch workflows,
create releases, or upload assets.

## Not Yet Implemented

- Private security advisory intake.
- Detached minisign signatures separate from GitHub/Sigstore attestations.
