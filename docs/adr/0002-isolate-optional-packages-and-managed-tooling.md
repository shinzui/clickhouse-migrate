# Isolate optional packages and managed tooling

Status: Accepted

Date: 2026-10-16

## Context

The migration engine must remain usable without compile-time embedding, CLI
policy or server-fixture dependencies. Contributors also need reproducible builds
across four sibling package roots. The generated template assumes a single root
package unless its built-in package output is disabled.

## Decision

Keep four public Cabal packages, with optional libraries depending on core and
no reverse edge. Production core exports no raw transport/ledger test interface.
A manual, default-off core executable builds private sources for qualification;
test-support invokes that executable without creating a package dependency cycle.
Its bootstrap entry point fails explicitly until EP-4 supplies runtime commands.
No pass-only suites are created for the scaffold.

Use `mori://shinzui/seihou-modules/templates/nix-haskell-flake` with the built-in
package disabled. Generated modules and the shipped lock remain managed.
`flake.module.nix` owns one recursive GHC 9.12.4 package set containing all four
packages and their checks. Future children extend that set and add behavioral
suites within their owning packages. The core is the default package output.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`; only the project
prelude enables PackageImports. Dependency bounds qualify the tested compiler
generation. Record registry/tag checks in [dependency evidence](../dependencies.md)
when expanding the closure.

## Consequences

Optional features can evolve without forcing their dependencies on core users.
Tests can reach private runtime code without weakening public invariants.
Toolchain changes arrive through Seihou upgrades, while project wiring survives
regeneration. Cabal distributions include package-local licenses and sources.
Build and formatter checks run on macOS and Linux; runtime support requires the
later real-server acceptance gates.
