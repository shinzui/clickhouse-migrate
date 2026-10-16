default:
    @just --list

build:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-embed test/fixtures/component/manifest.json -- build all

check-packages:
    #!/usr/bin/env bash
    set -euo pipefail
    for package in clickhouse-migrate clickhouse-migrate-embed clickhouse-migrate-cli clickhouse-migrate-test-support; do
      (cd "$package" && cabal check)
    done

# Behavioral suites are added by their owning implementation plans.
test-unit:
    cabal run clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- --input clickhouse-migrate-embed test/fixtures/component/manifest.json -- test all --test-show-details=direct

test-integration: test-transport test-completion-policy

format:
    nix fmt

check-format:
    nix fmt -- --fail-on-change

check: build check-packages test-unit check-public-invariants check-format

sdist:
    cabal sdist all

check-public-invariants:
    python3 scripts/check-public-invariants.py
    python3 scripts/checksum-reference.py --check

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
