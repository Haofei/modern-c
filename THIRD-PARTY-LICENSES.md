# Third-Party Licenses

This manifest summarizes the top-level vendored dependencies under
`third_party/` that carry a retained license file. The full license text remains
in each dependency's local license file; provenance and retained-subset details
remain in each `README.vendored.md`.

Generated trust-anchor material under `third_party/trust-anchors/` is not an
upstream source tree and has no top-level license file.

## BearSSL

- Component: BearSSL.
- Upstream and provenance: <https://www.bearssl.org/git/BearSSL>, commit
  `7bea48e5e850ab4cafbe68d3765cdaba13a86d6f`; see
  `third_party/bearssl/README.vendored.md`.
- License summary: MIT-style permissive license.
- Local license file: `third_party/bearssl/LICENSE.txt`.
- Redistribution note: retain the BearSSL copyright notice, permission notice,
  and warranty disclaimer in source or binary redistributions that include this
  dependency or substantial portions of it.

## QuickJS-NG

- Component: QuickJS-NG.
- Upstream and provenance: <https://github.com/quickjs-ng/quickjs>, recorded
  version `0.15.1`, tag `v0.15.1`, commit
  `fd0a0210b7be00957751871e7e01b8291268fc29`, source archive SHA-256
  `c4e813951b7c46845096a948e978c620b11ab4cf5fd622ca09c727ec31f42623`; see
  `third_party/quickjs/README.vendored.md`.
- License summary: MIT license.
- Local license file: `third_party/quickjs/LICENSE`.
- Redistribution note: retain the QuickJS-NG copyright notices, permission
  notice, and warranty disclaimer in source or binary redistributions that
  include this dependency or substantial portions of it.

## WAMR

- Component: WAMR, the WebAssembly Micro Runtime.
- Upstream and provenance:
  <https://github.com/bytecodealliance/wasm-micro-runtime>, recorded version
  `2.4.3`; exact recorded commit is currently unknown and must be recovered on
  the next re-vendor. See `third_party/wamr/README.vendored.md`.
- License summary: Apache-2.0 WITH LLVM-exception.
- Local license file: `third_party/wamr/LICENSE`.
- Redistribution note: provide a copy of the Apache License, Version 2.0; keep
  required copyright, patent, trademark, and attribution notices; mark modified
  files when distributing modified source; and preserve any upstream NOTICE text
  file if one is present.
- WAMR notice text: this vendored subset currently has no separate NOTICE file.
  If a future re-vendor imports one, preserve its attribution text in the
  redistributed source, documentation, NOTICE file, or generated third-party
  notices wherever such notices normally appear. The LLVM exception permits
  redistributing embedded object-form portions without Apache-2.0 Sections
  4(a), 4(b), and 4(d) for that embedded object form.

## openlibm

- Component: openlibm.
- Upstream and provenance: <https://github.com/JuliaMath/openlibm>, exact
  recorded version and commit currently unknown; local source evidence is the
  retained OpenLibm headers and `LICENSE.md`. See
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
