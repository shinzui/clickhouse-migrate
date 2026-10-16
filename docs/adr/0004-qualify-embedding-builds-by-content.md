# Qualify embedding builds by content

Status: Accepted

Date: 2026-10-16

## Context

The public embedding splice must follow manifest/SQL edits without requiring a
Haskell source edit. GHC 9.12.4's addDependentFile records content fingerprints,
but Cabal can return “Up to date” before invoking GHC when a file's modification
time is unchanged. The incremental harness reproduced stale embedded SQL after
a same-size, timestamp-preserving edit. A fresh GHC build embedded different bytes.

The inspected file-monitor source in `mori://haskell/cabal`, project-relative
`cabal/cabal-install/src/Distribution/Client/FileMonitor.hs` (artifact URI pending),
explicitly caches hashes by modification time. A compiler plugin alone cannot
correct a build that never invokes the compiler.

## Decision

The embedding package ships `clickhouse-migrate-embed-build`. Before invoking
Cabal, it validates explicitly declared package-root/manifest inputs and hashes
the manifest, every referenced SQL file, and their lexical/canonical paths.
A content token becomes part of Cabal's compiler-option configuration; a changed
token invalidates Cabal's cached build decision. The resulting compiler invocation
uses force-recomp, so source timestamp shortcuts cannot retain stale splices.
An unchanged token permits Cabal to reuse an already accepted artifact.

This is a build-time tool, never runtime migration discovery. It accepts explicit
inputs and Cabal build/test/haddock arguments. It prints no SQL and never contacts
a database. It uses the same manifest containment and definition validation as
the splice. The public splice also registers lexical/canonical file dependencies
using GHC's content-based compiler API; it reconstructs values exclusively through
public smart constructors. No compiler plugin or unchecked construction bridge
is introduced.

## Consequences

Use the qualified build entry point for consumers requiring timestamp-independent
embedding. Every manifest owning splices in the build must be declared to it.
Plain Cabal retains its own modification-time assumptions and is not qualified
for preserved-time edits. Direct GHC content dependency checks and Nix's content
addressed source builds are separate paths; neither fixes Cabal's skipped invocation.

The harness must compare every incremental qualified Cabal result with a fresh
GHC splice result, including same-size/preserved-time SQL and manifest edits,
entry changes, order, formatting, relocation and source-free execution. The
source distributions include the harness and fixtures. Build-tool changes must
rerun these cases before dropping the workaround.
