# Third-Party Licenses

This manifest summarizes the top-level vendored dependencies under
`third_party/` that carry a retained license file. The full license text remains
in each dependency's local license file; provenance and retained-subset details
remain in each `README.vendored.md`.

## openlibm

- Component: openlibm.
- Upstream and provenance: <https://github.com/JuliaMath/openlibm>, retained
  subset comparison commit `b8b7bec46076bbe5fee43ffe8f9b2a4c8352a9c8`, source
  archive SHA-256
  `b387919068d5ec49929cc012119375b889724175918e851851d3eacab92a665a`;
  the original import commit is not uniquely provable from retained files
  alone. Local source evidence is the retained OpenLibm headers and
  `LICENSE.md`. See
  `third_party/openlibm/README.vendored.md`.
- License summary: mixed permissive terms from the Julia project MIT license,
  ISC-licensed Stephen L. Moshier code, FreeBSD/2-clause BSD msun code, FDLIBM
  notice-preservation terms, OpenBSD libm heritage, and public-domain portions
  as noted by individual files. The local retained subset does not include the
  upstream LGPL test files described by the license file.
- Local license file: `third_party/openlibm/LICENSE.md`.
- Redistribution note: retain the applicable copyright notices, license
  conditions, permission notices, and disclaimers from `LICENSE.md`; preserve
  FDLIBM notices where applicable; reproduce binary-redistribution notices in
  documentation or other accompanying materials when required by the BSD terms.
