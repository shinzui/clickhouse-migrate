---
name: release
description: Release the clickhouse-migrate library packages to Hackage following PVP, with a single shared version
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# clickhouse-migrate Release Skill

Release the `clickhouse-migrate` library packages from this multi-package
repository to [Hackage](https://hackage.haskell.org/) using the Haskell PVP,
with a single shared version and one git tag per release.

## Versioning Strategy

All published packages share the **same version number** and are released
together. A single annotated git tag `v<version>` marks each release (prior
releases: `v0.1.0.0`, `v0.2.0.0`, `v0.2.1.0`). Always read the current version
from the cabal files rather than assuming it.

The three unpublished example packages (see below) are **versioned in lockstep**
with the published packages even though they never go to Hackage:
`just qualify-distributions` requires all seven packages at the same version.

The Haskell PVP version format is `A.B.C.D`:

- `A.B` is the **major** version — bump for breaking API changes (removed or
  renamed exports, changed types, changed semantics, changed on-disk/wire
  contracts such as checksum, SQL-envelope, manifest, ledger, adoption or JSON
  formats).
- `C` is the **minor** version — bump for backwards-compatible API additions
  (new exports, new modules, new instances).
- `D` is the **patch** version — bump for bug fixes, docs, internal-only
  changes, performance improvements.

Increment rules:

- **major**: increment `B`, reset `C` and `D` to 0 (`0.1.0.0` → `0.2.0.0`).
- **minor**: increment `C`, reset `D` to 0 (`0.1.0.0` → `0.1.1.0`).
- **patch**: increment `D` (`0.1.0.0` → `0.1.0.1`).

## Packages (in dependency order)

Publish in this order because of inter-package dependencies (each non-core
package depends on the core library via `clickhouse-migrate ==A.B.*`):

1. **clickhouse-migrate** — `clickhouse-migrate/` — core definitions and
   execution (no internal deps). **Publish first.**
2. **clickhouse-migrate-embed** — `clickhouse-migrate-embed/` — compile-time
   embedding (depends on `clickhouse-migrate`).
3. **clickhouse-migrate-cli** — `clickhouse-migrate-cli/` — reusable
   administrative CLI (depends on `clickhouse-migrate`).
4. **clickhouse-migrate-test-support** — `clickhouse-migrate-test-support/` —
   isolated server fixtures for consumers' tests (depends on
   `clickhouse-migrate`).

Packages 2–4 each depend only on the core library, so any order among them is
safe once core is published; the list above is the canonical order.

The following packages are **NOT released** to Hackage — they are the
in-repo example app that demonstrates composition:

- **clickhouse-migrate-example-catalog** — `examples/two-components/catalog/`
  (example migration component).
- **clickhouse-migrate-example-analytics** —
  `examples/two-components/analytics/` (example migration component).
- **clickhouse-migrate-example** — `examples/two-components/app/` (example
  executable).

They are not uploaded, but their `version:` is bumped with every release (step 3).

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — forces the bump level.
- If omitted, determine the bump level from the changes (step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from any package's `.cabal` file (line 3,
  `version:`; all packages share it).
- Find the latest git tag matching `v*` to identify the last release point:
  `git tag --list 'v*'` / `git describe --tags --abbrev=0`.
- Run `git log --oneline <last-tag>..HEAD`,
  `git diff --stat <last-tag>..HEAD`, and read the `## Unreleased` sections of
  the root and per-package `CHANGELOG.md` files (developers record entries
  there as they go).
- If there are no commits since the last tag, tell the user there is nothing
  to release and stop.

Present a summary: current version, last release tag (or "none — first
release"), number of commits since last release, and which package
directories changed.

### 2. Determine the next version using PVP

- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- Otherwise analyze the commits (Conventional Commits prefixes help):
  - breaking / removed / renamed / changed type / `!` / `BREAKING CHANGE`,
    or any change to a versioned contract → **major**.
  - `feat` / new export / new module → **minor**.
  - `fix` / `docs` / `refactor` / `test` / `chore` / internal → **patch**.
- Confirm against the actual source diff, not just commit prefixes:
  `git diff <last-tag>..HEAD -- */src`. Only modules in each cabal's
  `exposed-modules` are public; the `ClickHouseMigrate.Internal.*` modules are
  `other-modules`, so changes there (including new constructors on types whose
  constructors are not exported) are not breaking. Check export lists for
  removed/changed names and new exported constructors (the latter is major —
  consumers' exhaustive matches break).
- Present the proposed bump and the resulting version, and **ask the user to
  confirm before proceeding**.

### 3. Update versions, internal bounds, and changelogs

#### Version update

Edit the `version:` field (line 3) in **all seven** cabal files — the four
published packages and the three unpublished examples:

- `clickhouse-migrate/clickhouse-migrate.cabal`
- `clickhouse-migrate-embed/clickhouse-migrate-embed.cabal`
- `clickhouse-migrate-cli/clickhouse-migrate-cli.cabal`
- `clickhouse-migrate-test-support/clickhouse-migrate-test-support.cabal`
- `examples/two-components/catalog/clickhouse-migrate-example-catalog.cabal`
- `examples/two-components/analytics/clickhouse-migrate-example-analytics.cabal`
- `examples/two-components/app/clickhouse-migrate-example.cabal`

`sed` in the dev shell is GNU sed: use `sed -i '3s/^version: OLD$/version: NEW/'`
(no `''` after `-i`). Verify with `grep -n '^version' */*.cabal examples/*/*/*.cabal`
that all seven are at the target version. Skipping the examples makes
`just qualify-distributions` fail with a missing
`clickhouse-migrate-example-catalog-<version>.tar.gz`.

#### Internal dependency bounds

Every sibling reference uses a major-series bound `==A.B.*`:

- embed, cli and test-support pin `clickhouse-migrate ==A.B.*`;
  `clickhouse-migrate-test-support`'s integration test-suite also pins
  `clickhouse-migrate-cli` and `clickhouse-migrate-embed`;
- the examples pin `clickhouse-migrate`, `clickhouse-migrate-embed`,
  `clickhouse-migrate-cli`, `clickhouse-migrate-test-support` and each other.

- For a **patch** or **minor** bump, these bounds stay valid — leave them
  unchanged.
- For a **major** bump (e.g. `0.2.x` → `0.3.0.0`), update every internal
  `==A.B.*` bound to the new series in all of them. Find them with
  `grep -n 'clickhouse-migrate[a-z-]* ==' */*.cabal examples/*/*/*.cabal`.

#### Changelogs

The root `CHANGELOG.md` and each published package's `CHANGELOG.md` exist.
Developers add entries under a `## Unreleased` heading as they work.

- Replace `## Unreleased` with `## <version> — YYYY-MM-DD` (today's date, em
  dash, matching earlier sections), above previous entries.
- Regroup the Unreleased bullets — plus anything from the commits they missed —
  under **Breaking Changes** (major), **New Features** (minor/major),
  **Bug Fixes**, and **Other Changes**, including only non-empty groups. Wrap
  lines at ~80 columns like the existing sections.
- A published package with no changes still gets a section, e.g.
  `### Other Changes` / `- Release alongside the <version> core; no changes to
  this package.`

#### User docs

New APIs are documented in `docs/user/` (an OKF bundle) as unreleased while
they are in development. Find that wording and update it for the release:

```bash
grep -rnE 'unreleased|source.candidate|not (in|part of) (the )?published' README.md docs/user
```

- Replace "unreleased / source-candidate / not in published X" with
  "available since <version>". Removing `(unreleased)` from a heading changes
  its anchor — fix any links to it (e.g. `cli.md` links into `operations.md`).
- Add a short release note to `docs/user/compatibility.md` stating what the
  release changes for compatibility (contracts, runtime versions).
- Add an entry to `docs/user/log.md` under today's `## YYYY-MM-DD` heading
  (create it if missing), naming the touched docIds — `just check` runs
  `okf validate --log-enforce`.

Show the user **all** changes (version bumps, any bounds changes, changelog
entries, docs edits) for review before committing.

### 4. Verify builds and run the release gates

Run from the repo root, inside `nix develop` (the pinned GHC 9.12.4 shell):

- `nix fmt` — format (treefmt / fourmolu). Newly created files must be
  `git add`-ed before nix evaluation sees them (nix reads the git tree).
- `just check` — the full project gate: builds via the compile-time embed
  driver, `cabal check` on every package, the unit suites
  (`clickhouse-migrate-unit`, `clickhouse-migrate-embed-test`,
  `clickhouse-migrate-cli-test`), public-invariant / contract checks, docs and
  review (OKF) checks, and `--fail-on-change` format verification.
- `just qualify-distributions` — **the release-grade gate**: builds sibling
  `cabal sdist all` archives, runs `cabal check` on each extracted tarball,
  and runs the full native matrix against the archived sources. This proves
  the exact source distributions that will go to Hackage build and pass, so
  do not skip it.
  - It takes about **15–20 minutes**: ~3.5 min to build the archives, unit
    suites and Haddocks, then ~54 sequential server cases across three
    candidates (native LTS plus two Altinity Linux arm64 images in Apple
    Container VMs, with Keeper/replica fixtures and deliberate timeout waits).
    Run it with `run_in_background` and redirect output to a log in the
    scratchpad. Success ends with `Seven archives, metadata, three pure suites,
    Haddocks and the full native matrix passed`.
  - The Linux candidates need Apple Container running (`container system start`)
    with the matrix images pre-pulled.
- `nix flake check --builders '' --accept-flake-config` — the CI gate
  (treefmt + pre-commit). It starts no servers, so it can run in parallel with
  `just qualify-distributions`.

`just check` takes a few minutes; it can also run in the background. Grepping
its log for "error" or "fail" gives false positives (fault-injection case names
such as `LateError`, "fail-closed"); rely on the exit code and the final lines.

If any gate fails, fix the issue and re-run before proceeding. If you change
any file after a gate passed, re-run at least `just check` before committing.
Do not publish on a failing gate.

### 5. Commit, tag, and push

- Stage the modified `.cabal` files (all seven), all `CHANGELOG.md` files and
  the `docs/user` edits (`git add -u` covers them when no new files were
  created). The pre-commit hooks (treefmt and others) run on commit.
- Create a single commit with a Conventional Commits message:
  `chore(release): <new-version>`. The body summarizes what is in the release
  and why this bump was chosen.
- Create a single annotated tag: `git tag -a v<version> -m "Release <version>"`.
- Push: `git push && git push --tags`.

The commit and tag are created **only after** the user approves all changes
(step 3).

### 6. Publish to Hackage (in dependency order)

Publishing is **irreversible**. Prepare every artifact first, then ask the
user for one final explicit confirmation before the first upload.

**Prepare (after the tag is pushed, from the committed tree):**

1. Build the four source tarballs into the scratchpad:
   `cabal sdist clickhouse-migrate clickhouse-migrate-embed clickhouse-migrate-cli clickhouse-migrate-test-support --output-directory <scratchpad>/release/sdist`
   (do not pass `all` — that includes the unpublished examples).
2. Run `cabal check` in each published package directory (final guard).
3. Build the Haddock tarballs:
   `cabal haddock <pkg> --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`
   for each package. They land at `dist-newstyle/<pkg>-<version>-docs.tar.gz`.
   A plain `cabal haddock` works for all four (verified for 0.2.1.0, including
   `clickhouse-migrate-embed`; its library docs don't need an embedded
   manifest). Only if that ever fails, mirror the `just haddock` recipe and run
   it through
   `cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input <pkg-dir> <manifest> -- haddock <pkg> ...`.

**Upload**, for EACH package in the order clickhouse-migrate →
clickhouse-migrate-embed → clickhouse-migrate-cli →
clickhouse-migrate-test-support:

1. `cabal upload --publish <sdist-tarball>`.
2. `cabal upload --publish --documentation dist-newstyle/<pkg>-<version>-docs.tar.gz`.
3. Report the Hackage URL:
   `https://hackage.haskell.org/package/<pkg>-<version>`.

A single `bash -c 'set -e; for p in ...; do ...; done'` inside `nix develop`
uploads all four in order and stops at the first failure. Credentials come from
the user's cabal config; never print or pass them on the command line.

If an upload fails for a package, **stop** — do not upload any package that
depends on it (never publish a dependent after its upstream upload failed).

After all packages are published, present a summary:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| clickhouse-migrate | X.Y.Z.W | https://hackage.haskell.org/package/clickhouse-migrate-X.Y.Z.W |
| clickhouse-migrate-embed | X.Y.Z.W | https://hackage.haskell.org/package/clickhouse-migrate-embed-X.Y.Z.W |
| clickhouse-migrate-cli | X.Y.Z.W | https://hackage.haskell.org/package/clickhouse-migrate-cli-X.Y.Z.W |
| clickhouse-migrate-test-support | X.Y.Z.W | https://hackage.haskell.org/package/clickhouse-migrate-test-support-X.Y.Z.W |

### 7. Create the GitHub release

After all Hackage uploads succeed, create a GitHub release for the tag:

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Packages

| Package | Hackage |
|---------|---------|
| clickhouse-migrate | https://hackage.haskell.org/package/clickhouse-migrate-X.Y.Z.W |
| clickhouse-migrate-embed | https://hackage.haskell.org/package/clickhouse-migrate-embed-X.Y.Z.W |
| clickhouse-migrate-cli | https://hackage.haskell.org/package/clickhouse-migrate-cli-X.Y.Z.W |
| clickhouse-migrate-test-support | https://hackage.haskell.org/package/clickhouse-migrate-test-support-X.Y.Z.W |

## What's Changed

<changelog entries for this version from the root CHANGELOG.md>
EOF
)"
```

Use the root `CHANGELOG.md` entries for the body, include the Hackage links
table, and report the GitHub release URL when done.

## Important

- Always ask the user to confirm the version bump and changelogs **before**
  committing.
- Bump all seven cabal versions (four published + three examples) together.
- Ask for a separate, explicit confirmation immediately before the first
  Hackage upload; approval to commit/tag/push does not cover publishing.
- Always publish in dependency order: clickhouse-migrate → embed → cli →
  test-support.
- Never skip the gates: `nix fmt`, `just check`, `just qualify-distributions`,
  and `nix flake check`.
- If any step fails (including a gate), stop and report the error rather than
  continuing.
- If a Hackage upload fails for a package, do **not** continue uploading
  packages that depend on it.
- The commit and tag are created only AFTER user approval of all changes.
