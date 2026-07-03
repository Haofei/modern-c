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
2. Run `zig build m0` in the pinned Linux container with no skips.
3. Run `zig build fast` on every supported host tier.
4. Generate Linux and macOS tarballs containing `bin/mcc`, `std/`, driver scripts,
   `README.md`, `LICENSE`, `SECURITY.md`, `STABILITY.md`, and `CHANGELOG.md`.
5. Publish SHA256 checksums for every artifact.
6. Tag the exact commit and record the tag in `CHANGELOG.md`.

## Not Yet Implemented

- Cross-platform release workflow.
- Signed/checksummed artifact publication.
- Install-prefix stdlib lookup.
- Private security advisory intake.
