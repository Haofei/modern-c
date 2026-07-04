# openlibm (vendored)

- **Upstream:** <https://github.com/JuliaMath/openlibm>
- **Recorded version:** no upstream release tag or version macro is retained in
  this tree. The retained subset does not match release tag `v0.8.7` exactly.
- **Retained-subset comparison commit:**
  `b8b7bec46076bbe5fee43ffe8f9b2a4c8352a9c8`.
- **Source archive:**
  <https://codeload.github.com/JuliaMath/openlibm/tar.gz/b8b7bec46076bbe5fee43ffe8f9b2a4c8352a9c8>.
- **Archive SHA-256:**
  `b387919068d5ec49929cc012119375b889724175918e851851d3eacab92a665a`.
- **Source evidence:** `LICENSE.md` identifies the tree as OpenLibm derived from
  FreeBSD msun and OpenBSD libm; headers under `include/` expose the OpenLibm
  API and `isopenlibm()` marker.
- **Provenance limit:** all retained files match the comparison commit
  byte-for-byte, but the original import commit is not uniquely provable from
  retained files alone because adjacent upstream commits can change files that
  this local subset dropped.
- **License:** mixed permissive licenses inherited from OpenLibm, FreeBSD msun,
  and OpenBSD libm (see `LICENSE.md`)

## What is kept

The committed subset keeps the freestanding libm surface used by confined C
apps, QuickJS, and WAMR hosts:

- `include/` OpenLibm public headers.
- `src/` libm sources and private headers.
- `LICENSE.md`.

Upstream build-system files, tests, documentation, packaging files, and platform
integration not needed by the local freestanding archive were dropped.

## Local modifications

No retained source, header, or license file differs from comparison commit
`b8b7bec46076bbe5fee43ffe8f9b2a4c8352a9c8`. The local integration is outside the
vendored source, primarily in `tools/user/build-openlibm.sh`, which compiles the
subset with freestanding target flags and skips translation units that do not
compile for the selected target.

The next openlibm re-vendor must replace the retained subset from an explicit
tag or commit, record the source archive checksum, and preserve a diff of any
local changes.

## How it is built and used

`tools/user/build-openlibm.sh` compiles `third_party/openlibm/src/*.c` with
freestanding target flags and archives the objects that build successfully into
`libopenlibm.a`. Long-double, complex, Bessel, and lgamma files that do not
compile for the active freestanding target are skipped; missing symbols fail at
final link rather than being stubbed.

`tools/user/build-app.sh` links the archive last for confined C apps so only
referenced math members are pulled. The archive supplies the double-precision
transcendental functions used by QuickJS `Math` and WAMR/wasm agent tests.
