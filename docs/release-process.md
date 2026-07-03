# Release Process

Status: draft process for future `mcc` releases. No release artifacts are currently
published.

## Version Identity

The development version is `0.7.0-dev`.

- `build.zig.zon` records the package version and minimum Zig version.
- `.zigversion` pins the local/CI Zig toolchain.
- `zig build -Dversion=<version>` controls the string reported by `mcc --version`.
- Without `-Dversion`, local builds report `mcc 0.7.0-dev`.

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
7. Generate Linux and macOS tarballs containing `bin/mcc`, `std/`, driver scripts,
   `README.md`, `LICENSE`, `SECURITY.md`, `STABILITY.md`, and `CHANGELOG.md`.
8. Publish SHA256 checksums for every artifact.
9. Tag the exact commit and record the tag in `CHANGELOG.md`.

## Not Yet Implemented

- Cross-platform release workflow.
- Signed/checksummed artifact publication.
- Install-prefix stdlib lookup.
- Private security advisory intake.
