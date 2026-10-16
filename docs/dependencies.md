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

## Pure definition model — 2026-10-16

Mori-located sources inspected before use:
`mori://haskell/bytestring/packages/bytestring` (Builder field encoding),
`mori://haskell/text/packages/text` (strict UTF-8 decode/encode),
`mori://haskell/containers/packages/containers` (Map/Set graph validation), and
`mori://haskell-hvr/cryptohash-sha256/packages/cryptohash-sha256` (pure strict
ByteString `hash`, which returns raw digest bytes).

Hackage preferred-version metadata and matching upstream tags were checked:
bytestring 0.12.2.0 (tag `0.12.2.0`, `d984ad00644c0157bad04900434b9d36f23633c5`),
text 2.1.4 (tag `2.1.4`, `423fd981e576bd17a8b5fa48d0ad6b9a0c370e77`),
containers 0.8.1 (tag `v0.8.1`, `953428ad079d5708df696442f9bdeaccd1acfc6c`),
and cryptohash-sha256 0.11.102.1 (tag `v0.11.102.1`,
`89c1b9030989cc914d057061d90933628481abb2`). Chosen bounds are bytestring
`>=0.12.2 && <0.13`, text `>=2.1 && <2.2`, containers `>=0.7 && <0.9`,
and cryptohash-sha256 `>=0.11.102.1 && <0.12`. The lower containers/text
bounds accommodate the pinned compiler's bundled libraries without a workaround.
Cabal resolved/tested bytestring 0.12.2.0, text 2.1.4, containers 0.7 and
cryptohash-sha256 0.11.102.1 on GHC 9.12.4. The Nix package set independently
checks the same public bounds and runs the unit suite.

## Compile-time embedding — 2026-10-16

Mori-located `mori://haskell/aeson/packages/aeson` source was inspected for the
public Decoding.ByteString/Tokens interfaces and duplicate-preserving token
representation; normal object decoding would discard duplicate evidence.
`mori://haskell/directory` supplied canonicalization/ancestor/file checks, and
`mori://haskell/process/packages/process` supplied `callProcess`'s argument-vector
execution. Existing core ByteString/Text/Set/SHA-256 APIs are reused.

Hackage preferred releases and upstream tags were verified: aeson 2.3.2.0
(tag `v2.3.2.0`, `682162c66d26a770fbfb6271c797e646bc5c4f2e`),
directory 1.3.11.0 (tag `v1.3.11.0`, `12d17af8ee2f84fc6b6ac0d4e1734952789ddd3e`),
filepath 1.5.5.0 (tag `v1.5.5.0`, `baac7d7e76449f76fc6785e77206edb5530b6bfb`),
and process 1.6.30.0 (tag `v1.6.30.0`, `11fd247ad33208da7a914acf15d4a09d64a6a4c4`).
Bounds are aeson >=2.2.4.1 && <2.4, directory >=1.3.10 && <1.4,
filepath >=1.5.4 && <1.6, process >=1.6.25 && <1.7, and the compiler's
bundled template-haskell >=2.23 && <2.24. Hackage reports template-haskell
2.24.0.0 as latest; this project qualifies the pinned 2.23.0.0 compiler generation.

Mori lookup found no registered GHC/template-haskell or filepath source project.
The pinned compiler's authoritative upstream source at GHC 9.12.4 release commit
`44c6796f535d60861fa2510025ec79f27696a15e` was therefore read directly:
`mori://ghc/ghc`, project-relative
`libraries/ghc-internal/src/GHC/Internal/TH/Syntax.hs`,
`compiler/GHC/Tc/Gen/Splice.hs` and `compiler/GHC/Iface/Recomp.hs`
(artifact URIs pending). It confirms addDependentFile expects absolute paths and
compares contents; getPackageRoot uses the compiler working directory.
The `mori://haskell/filepath` source was checked directly at its matching
1.5.5.0 upstream tag (file-level URI coverage pending).

The Cabal timestamp-cache counterexample and content-qualified build workaround
are recorded in [ADR 0004](adr/0004-qualify-embedding-builds-by-content.md).
A compiler plugin cannot fix Cabal skipping the compiler invocation. No private
compiler API or plugin dependency is needed.

Cabal resolved and tested aeson 2.3.2.0, directory 1.3.10.1, filepath 1.5.5.0,
process 1.6.26.1 and template-haskell 2.23.0.0 on the pinned GHC 9.12.4.
The Nix package build separately exercises its pinned aeson 2.2 generation
against the same public bounds. No Linux execution is included in this evidence.

Before retaining the Cabal compatibility workaround, Hackage's latest released
cabal-install 3.18.2.0 and upstream tag `cabal-install-v3.18.2.0`
(`45f982c12ef78ea8ec5beb43cb8c71c8e8f237c1`) were checked. Its authoritative
FileMonitor source still uses modification-time equality to reuse content hashes.
The measured runtime remains the template's 3.16.1.0, tag
`cabal-install-v3.16.1.0` (`8d1f5a33662be0db0654061fb53fb00e3f4417e0`).
The workaround is not based only on a lagging local source checkout; no ad hoc
managed-toolchain pin was changed.
