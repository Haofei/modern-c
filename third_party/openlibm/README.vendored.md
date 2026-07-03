# openlibm (vendored)

- **Upstream:** <https://github.com/JuliaMath/openlibm>
- **Recorded version:** unknown. No upstream version macro, commit, tag file, or
  archive checksum is present in this tree.
- **Source evidence:** `LICENSE.md` identifies the tree as OpenLibm derived from
  FreeBSD msun and OpenBSD libm; headers under `include/` expose the OpenLibm
  API and `isopenlibm()` marker.
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

No local patch markers are present in the vendored openlibm files. The local
integration is in `tools/user/build-openlibm.sh`, which compiles the subset with
freestanding target flags and skips translation units that do not compile for
the selected target.

Because the exact upstream version/commit is unknown, the next openlibm
re-vendor must identify the imported upstream tag or commit, record an archive
checksum, and preserve a diff of any local changes before replacing this tree.

## How it is built and used

`tools/user/build-openlibm.sh` compiles `third_party/openlibm/src/*.c` with
freestanding target flags and archives the objects that build successfully into
`libopenlibm.a`. Long-double, complex, Bessel, and lgamma files that do not
compile for the active freestanding target are skipped; missing symbols fail at
final link rather than being stubbed.

`tools/user/build-app.sh` links the archive last for confined C apps so only
referenced math members are pulled. The archive supplies the double-precision
transcendental functions used by QuickJS `Math` and WAMR/wasm agent tests.
