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
together. A single annotated git tag `v<version>` marks each release. They are
currently all at `0.1.0.0`.

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
package depends on `clickhouse-migrate ^>=` the core library):

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
- If there are tags, run `git log --oneline <last-tag>..HEAD`; if there are no
  tags yet, this is the **first release** — summarize `git log --oneline`
  instead and treat the current `0.1.0.0` as the release version unless the
  user asks to bump it.
- If there are no commits since the last tag, tell the user there is nothing
  to release and stop.

Present a summary: current version, last release tag (or "none — first
release"), number of commits since last release, and which package
directories changed.

### 2. Determine the next version using PVP

- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- For the **first release** (no prior tag), default to keeping `0.1.0.0`
  unless the user supplied a bump.
- Otherwise analyze the commits (Conventional Commits prefixes help):
  - breaking / removed / renamed / changed type / `!` / `BREAKING CHANGE`,
    or any change to a versioned contract → **major**.
  - `feat` / new export / new module → **minor**.
  - `fix` / `docs` / `refactor` / `test` / `chore` / internal → **patch**.
- Present the proposed bump and the resulting version, and **ask the user to
  confirm before proceeding**.

### 3. Update versions, internal bounds, and changelogs

#### Version update

Edit the `version:` field (line 3) in each published cabal to the new version:

- `clickhouse-migrate/clickhouse-migrate.cabal`
- `clickhouse-migrate-embed/clickhouse-migrate-embed.cabal`
- `clickhouse-migrate-cli/clickhouse-migrate-cli.cabal`
- `clickhouse-migrate-test-support/clickhouse-migrate-test-support.cabal`

Verify all four are at the target version before committing.

#### Internal dependency bounds

The non-core packages pin the core library as `clickhouse-migrate ==0.1.*`,
and `clickhouse-migrate-test-support`'s integration test-suite also pins
`clickhouse-migrate-cli ==0.1.*` and `clickhouse-migrate-embed ==0.1.*`.

- For a **patch** or **minor** bump within the current `0.1.*` series, these
  `==0.1.*` bounds stay valid — leave them unchanged.
- For a **major** bump (e.g. `0.1.x` → `0.2.0.0`), update every internal
  `==0.N.*` bound to the new major series (`==0.2.*`) in all packages that
  reference a sibling (embed, cli, test-support — including the test-suite
  build-depends in `clickhouse-migrate-test-support`). Grep for
  `clickhouse-migrate ==` and `clickhouse-migrate-cli ==` /
  `clickhouse-migrate-embed ==` to find them all.

#### Changelogs

There are currently **no `CHANGELOG.md` files**. Create a `CHANGELOG.md` in
each published package directory on the first release (and maintain them
after), plus a root `CHANGELOG.md`.

- Add a new section for the new version above previous entries, dated today in
  `YYYY-MM-DD` format.
- Move any "Unreleased" content into the new section.
- Summarize commits since the last release, grouped as **Breaking Changes**
  (major), **New Features** (minor/major), **Bug Fixes**, and **Other
  Changes** — include only non-empty groups.

Show the user **all** changes (version bumps, any bounds changes, changelog
entries) for review before committing.

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
- `nix flake check --builders '' --accept-flake-config` — the CI gate
  (treefmt + pre-commit).

If any gate fails, fix the issue and re-run before proceeding. Do not publish
on a failing gate.

### 5. Commit, tag, and push

- Stage the modified `.cabal` files and all `CHANGELOG.md` files.
- Create a single commit with a Conventional Commits message:
  `chore(release): <new-version>`. The body summarizes what is in the release
  and why this bump was chosen.
- Create a single annotated tag: `git tag -a v<version> -m "Release <version>"`.
- Push: `git push && git push --tags`.

The commit and tag are created **only after** the user approves all changes
(step 3).

### 6. Publish to Hackage (in dependency order)

Publishing is **irreversible**. For EACH package, in the order
clickhouse-migrate → clickhouse-migrate-embed → clickhouse-migrate-cli →
clickhouse-migrate-test-support:

1. `cabal sdist <pkg>` to build the source tarball (or reuse the archive from
   `just qualify-distributions`).
2. `cabal check` in the package directory (already covered by the gate; this
   is a final guard).
3. `cabal upload --publish <tarball-path>` to publish the source distribution.
4. Upload Haddock documentation:
   `cabal haddock <pkg> --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`
   then `cabal upload --publish --documentation <docs-tarball-path>`.
   - **Note:** `clickhouse-migrate-embed` embeds SQL at compile time, so
     generating its Haddock needs the embed inputs. Mirror the `just haddock`
     recipe — run the build through
     `cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-embed test/fixtures/component/manifest.json -- haddock clickhouse-migrate-embed ...`
     — if a plain `cabal haddock` fails for want of an embedded manifest. If
     Hackage's own doc builder is preferred for a package, you may skip the
     manual docs upload for it.
5. Report the Hackage URL:
   `https://hackage.haskell.org/package/<pkg>-<version>`.

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
- Always publish in dependency order: clickhouse-migrate → embed → cli →
  test-support.
- Never skip the gates: `nix fmt`, `just check`, `just qualify-distributions`,
  and `nix flake check`.
- If any step fails (including a gate), stop and report the error rather than
  continuing.
- If a Hackage upload fails for a package, do **not** continue uploading
  packages that depend on it.
- The commit and tag are created only AFTER user approval of all changes.
