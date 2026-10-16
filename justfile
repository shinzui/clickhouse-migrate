default:
    @just --list

build:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-embed test/fixtures/component/manifest.json --input examples/two-components/catalog migrations/manifest.json --input examples/two-components/analytics migrations/manifest.json -- build all

check-packages:
    #!/usr/bin/env bash
    set -euo pipefail
    for package in clickhouse-migrate clickhouse-migrate-embed clickhouse-migrate-cli clickhouse-migrate-test-support examples/two-components/catalog examples/two-components/analytics examples/two-components/app; do
      (cd "$package" && cabal check)
    done

# Behavioral suites are added by their owning implementation plans.
test-unit:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-embed test/fixtures/component/manifest.json --input examples/two-components/catalog migrations/manifest.json --input examples/two-components/analytics migrations/manifest.json -- test clickhouse-migrate-unit clickhouse-migrate-embed-test clickhouse-migrate-cli-test --test-show-details=direct

test-integration: test-release-matrix

format:
    nix fmt

check-format:
    nix fmt -- --fail-on-change

check: build check-packages test-unit check-public-invariants check-docs check-reviews check-format

check-reviews:
    dhall type --file mori/reviews-profile.dhall > /dev/null
    okf validate docs/reviews --strict --profile mori/reviews-profile.dhall --profile-enforce --log-enforce
    okf graph docs/reviews --json > /dev/null

check-docs:
    dhall type --file mori/user-documentation-profile.dhall > /dev/null
    dhall type --file mori.dhall > /dev/null
    okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
    okf graph docs/user --json > /dev/null

sdist:
    cabal sdist all

check-public-invariants:
    python3 scripts/check-public-invariants.py
    python3 scripts/checksum-reference.py --check
    python3 scripts/adoption-reference.py --check

test-embedding:
    bash scripts/test-embedding-rebuild.sh
    python3 scripts/check-embedding-failures.py

test-transport:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal build clickhouse-migrate:exe:clickhouse-migrate-test-driver -finternal-test-driver
    driver=$(cabal list-bin clickhouse-migrate:exe:clickhouse-migrate-test-driver -finternal-test-driver)
    CLICKHOUSE_MIGRATE_TEST_DRIVER="$driver" cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=transport

test-completion-policy:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal build clickhouse-migrate:exe:clickhouse-migrate-test-driver -finternal-test-driver
    driver=$(cabal list-bin clickhouse-migrate:exe:clickhouse-migrate-test-driver -finternal-test-driver)
    CLICKHOUSE_MIGRATE_TEST_DRIVER="$driver" cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=completion

test-ledger:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal build clickhouse-migrate:exe:clickhouse-migrate-test-driver -finternal-test-driver
    driver=$(cabal list-bin clickhouse-migrate:exe:clickhouse-migrate-test-driver -finternal-test-driver)
    CLICKHOUSE_MIGRATE_TEST_DRIVER="$driver" cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=ledger

test-exclusive-access:
    cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=exclusive

test-runner:
    cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=runner

test-repair:
    cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=repair

test-failure-boundaries:
    cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=boundaries
    cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=survivors

test-adoption:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-test-support test/fixtures/kansoku/manifest.json --input clickhouse-migrate-test-support test/fixtures/kansoku/manifest-first.json -- test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=adoption

test-consumer-fixtures:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-test-support test/fixtures/kansoku/manifest.json --input clickhouse-migrate-test-support test/fixtures/kansoku/manifest-first.json -- test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=consumer

# Build all live-test artifacts with every embedded input declared.
build-qualification:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-test-support test/fixtures/kansoku/manifest.json --input clickhouse-migrate-test-support test/fixtures/kansoku/manifest-first.json --input examples/two-components/catalog migrations/manifest.json --input examples/two-components/analytics migrations/manifest.json -- build clickhouse-migrate-test-support:test:clickhouse-migrate-integration clickhouse-migrate:exe:clickhouse-migrate-test-driver clickhouse-migrate-example -fintegration -finternal-test-driver

test-release-matrix: build-qualification
    python3 scripts/test-release-matrix.py

test-cli:
    cabal test clickhouse-migrate-cli-test --test-show-details=direct

test-example: build-qualification
    #!/usr/bin/env bash
    set -euo pipefail
    example=$(cabal list-bin clickhouse-migrate-example)
    suite=$(cabal list-bin clickhouse-migrate-integration -fintegration)
    clickhouse_migrate_test_support_datadir="$PWD/clickhouse-migrate-test-support" CLICKHOUSE_MIGRATE_EXAMPLE="$example" "$suite" example

check-production-closure:
    python3 scripts/check-production-closure.py

haddock:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input examples/two-components/catalog migrations/manifest.json --input examples/two-components/analytics migrations/manifest.json -- haddock all

qualify-distributions:
    python3 scripts/qualify-distributions.py
