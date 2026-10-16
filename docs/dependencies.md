# Dependency evidence

Record each new dependency's canonical Mori source, inspected API, authoritative
registry release and upstream tag, chosen bounds, and versions actually tested.
Bounds describe the qualified range, rather than claiming every newer release.
The shared Seihou lock owns build-tool pins; do not independently update them.

## Workspace baseline — 2026-10-16

`mori://shinzui/seihou-modules/templates/nix-haskell-flake` version 0.30.0,
source revision `3a6eebdd0c6a5b594a665dbb5e08f47f69053449`, was inspected and applied
with a conflict-free preview. Registry metadata lagged at 0.26.0. The generated
lock and revision URLs are the template's exact shipped pair; no dependency
workaround or toolchain upgrade was introduced. The upstream repository had no
0.30 release tag at inspection. This template's source version is recorded rather
than inventing a release tag.

The baseline compiler is GHC 9.12.4 with base 4.21.2.0 and cabal-install 3.16.1.0.
[Hackage base metadata](https://hackage.haskell.org/package/base/preferred.json)
reports latest base 4.22.0.0, and includes 4.21.2.0. The upstream GHC
`ghc-9.12.4-release` tag resolves to
`44c6796f535d60861fa2510025ec79f27696a15e`. The base bound is
`>=4.21 && <4.22`, deliberately limited to the compiler generation currently
qualified. The compiler is selected by Seihou's shared pin, not by a claim that
9.12.4 is newest. Mori registry search found no GHC/base source project; standard
base module imports need no version-specific workaround.

Cabal package/common-stanza/flag behavior was checked against the local
`mori://haskell/cabal` source, project-relative
`cabal/doc/cabal-package-description-file.rst` (artifact-level URI pending).
The project language/import/record conventions are
`mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`,
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns` and
`mori://shinzui/haskell-jitsurei/docs/core-multiline-strings`.

All four bootstrap libraries depend on base; the three optional packages depend
on the matching local core 0.1 release. Core has no optional package dependency.
The prelude intentionally starts with base re-exports; later plans add only the
shared dependencies they actually need, with release/API evidence here.

Validation results are recorded in EP-1; runtime and server support are not
qualified by this baseline.

CI actions were checked against their authoritative GitHub latest-release metadata
and matching upstream tags on 2026-10-16: checkout v7.0.1
(`3d3c42e5aac5ba805825da76410c181273ba90b1`), nix-installer-action v23
(`3138316df39ed29be04236d7ffc686fa525866aa`), and cachix-action v17
(`38b082610b782e7e93e209c35fd730d399dee866`). The workflow pins these commits.
