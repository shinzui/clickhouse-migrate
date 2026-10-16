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

# EP-4 will add the owned server fixture and private driver invocation.
test-integration:
    @echo 'Integration fixture is not implemented yet (EP-4).' >&2
    @exit 1

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
