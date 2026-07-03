# Release Process

Status: draft release process with an implemented Linux and macOS artifact
workflow. Release publication is still conservative: the workflow builds
tarballs, checksums, a release inventory, and a CycloneDX SBOM. No public stable
release has been cut yet.

## Version Identity

The development version is `0.7.0-dev`.

- `build.zig.zon` records the package version and minimum Zig version.
- `.zigversion` pins the local/CI Zig toolchain.
- `zig build -Dversion=<version>` controls the string reported by `mcc --version`.
- Without `-Dversion`, local builds report `mcc 0.7.0-dev`.
- Release tags use the `v<version>` form. The release workflow strips the leading
  `v` and passes `-Dversion=<version>` to Zig.

## Release Checklist

Before tagging a release:

1. Choose the release version and build with `zig build -Dversion=<version> install`.
2. Run `zig build m0` on Ubuntu 24.04 with LLVM 18 (`MC_LLVM_MAJOR=18`) and no skips.
3. Run `zig build m0` in the pinned Linux container with no skips.
4. Confirm the nightly rotating-seed mcfuzz workflow is green for the release
   candidate commit. Shrink any reported failing seed with `tools/fuzz/mcfuzz.py
   shrink` and commit the minimized repro under `tools/fuzz/corpus/` before
   tagging.
5. Confirm the nightly QEMU benchmark workflow is green for the release candidate
   commit. Its committed baseline lives in `tools/bench/nightly-baseline.tsv`; update
   the TSV only when a deliberate performance change is measured on the pinned
   Ubuntu 24.04 / Zig 0.16.0 / LLVM 18 toolchain.
6. Run `zig build fast` on every supported host tier.
7. For generated C or `.mcmap` artifacts kept for release audit, invoke `mcc
   emit-c` / `mcc emit-map` with `--remap-prefix=<build-root>=<logical-root>`
   so `#line` directives and source-map `source_path` metadata do not record
   host-specific temporary paths.
8. Run a manual dry run of `.github/workflows/release.yml` for the candidate
   version. The workflow builds with Zig 0.16.0, `-Doptimize=ReleaseSafe`, and
   `-Dversion=<version>` via `tools/ci/package-release.py`.
9. Confirm the dry-run workflow artifact contains tarballs for
   `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos`, and
   `aarch64-macos`.
   Each tarball must contain `bin/mcc`, `bin/mcc-real`, `std/`,
   `tools/toolchain/mcc-build.sh`, `tools/toolchain/mcc-cc.sh`,
   `tools/toolchain/mcc-llvm-cc.sh`, `README.md`, `LICENSE`, `SECURITY.md`,
   `STABILITY.md`, `CHANGELOG.md`, and `THIRD-PARTY-LICENSES.md`.
10. Confirm `SHA256SUMS`, `mcc-<version>-release-inventory.json`, and
   `mcc-<version>-sbom.cdx.json` are present and that
   `sha256sum -c SHA256SUMS` passes.
11. Sign the release artifact set before publishing. The current workflow emits
   checksums, inventory, and SBOM metadata; external minisign/cosign signing is
   still a manual release-manager step until signing keys and identity policy are
   documented.
12. Tag the exact commit and record the tag in `CHANGELOG.md`. Pushing `v*`
   creates or updates the GitHub Release assets with `gh release upload`.

## Release Artifacts

`.github/workflows/release.yml` runs on `v*` tags and manual dispatch. Manual
dispatch defaults to a dry run, which uploads workflow artifacts without creating
a GitHub Release. A tag run publishes the same artifact set to the GitHub Release
for that tag.

The packaging helper is intentionally local-testable:

```sh
python3 tools/ci/package-release.py release --version 0.7.0 \
  --targets x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos
```

The helper builds `mcc` with `zig build -Dtarget=<target> -Doptimize=ReleaseSafe
-Dversion=<version> install`, stages the required runtime files, writes a
deterministic tarball, emits release inventory and CycloneDX SBOM JSON files, and
writes `SHA256SUMS`.

The current target set is:

- `x86_64-linux-musl`
- `aarch64-linux-musl`
- `x86_64-macos`
- `aarch64-macos`

## Not Yet Implemented

- Private security advisory intake.
- Automated minisign/cosign signing in the release workflow.
