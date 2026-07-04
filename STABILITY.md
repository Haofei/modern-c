# Stability Policy

MC is currently `0.7.0-dev`. The language, compiler CLI, generated C/LLVM text, stdlib
APIs, and kernel support libraries are allowed to change without compatibility
guarantees until a tagged release declares its supported surfaces.

## Stable Enough To Depend On In-Repo

- The milestone gates named in `build/tiers.zig` are the compatibility contract for
  this repository.
- Diagnostic `E_*` codes listed in `docs/diagnostics.md` are tracked by a generated
  reference, but wording may still change when diagnostics improve.
- `mcc --version`, `mcc --help`, and documented exit-code behavior are transcript
  gated.

## Experimental Surfaces

- The CLI is not a released installation interface yet.
- `emit-c` and `emit-llvm` output formats are compiler artifacts, not stable public
  APIs.
- The package/registry scripts are local exact-version tooling, not a public package
  ecosystem.
- Async, traits, kernel libraries, editor integration, and self-hosted compiler
  slices remain subject to incompatible changes.

## Tagged Release Compatibility

The first `v*` tag may still be a development release, but it must state its
supported surfaces in the changelog. Unless that release note says otherwise, only
the release artifact layout, `mcc --version`, `mcc --help`, documented exit-code
behavior, and diagnostic `E_*` code identities are compatibility surfaces for that
tag. Language semantics, generated C/LLVM text, stdlib APIs, kernel libraries, and
editor integration remain experimental through `0.x`.

## Changing Behavior

Before removing or changing a documented feature, update tests and docs in the same
change. For user-visible deprecations, prefer a diagnostic or compatibility alias for
at least one development cycle when it does not preserve unsound behavior.
