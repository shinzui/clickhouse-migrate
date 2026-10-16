# Project-owned package wiring; the generated modules remain Seihou-owned.
{ ... }:
{
  perSystem = { pkgs, ... }:
    let
      hs = pkgs.haskell.packages.ghc9124.override {
        overrides = hself: _hsuper: {
          clickhouse-migrate = hself.callCabal2nix "clickhouse-migrate" ./clickhouse-migrate { };
          clickhouse-migrate-embed = hself.callCabal2nix "clickhouse-migrate-embed" ./clickhouse-migrate-embed { };
          clickhouse-migrate-cli = hself.callCabal2nix "clickhouse-migrate-cli" ./clickhouse-migrate-cli { };
          clickhouse-migrate-test-support = hself.callCabal2nix "clickhouse-migrate-test-support" ./clickhouse-migrate-test-support { };
        };
      };
      packages = {
        inherit (hs) clickhouse-migrate clickhouse-migrate-embed clickhouse-migrate-cli clickhouse-migrate-test-support;
      };
    in
    {
      packages = packages // {
        default = hs.clickhouse-migrate;
        internal-test-driver = pkgs.haskell.lib.compose.enableCabalFlag "internal-test-driver" hs.clickhouse-migrate;
      };
      checks = packages;
      haskellProject.extraDevPackages = [ pkgs.python3 pkgs.openssl ];
    };
}
