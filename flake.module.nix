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
        # Compile/install the opt-in suite with Nix dependencies. Owned servers
        # run explicitly outside the build, never during default package checks.
        integration-tests = pkgs.haskell.lib.compose.overrideCabal
          (old: {
            doCheck = true;
            # cabal2nix's default-off integration flag omits this test dependency.
            testHaskellDepends = (old.testHaskellDepends or [ ]) ++ [ hs.clickhouse-migrate-embed ];
            checkPhase = ''
              runHook preCheck
              echo "Integration suite built; run the installed executable explicitly for native qualification."
              runHook postCheck
            '';
            postInstall = (old.postInstall or "") + ''
              mkdir -p "$out/bin"
              cp dist/build/clickhouse-migrate-integration/clickhouse-migrate-integration "$out/bin/"
            '';
          })
          (pkgs.haskell.lib.compose.enableCabalFlag "integration" hs.clickhouse-migrate-test-support);
      };
      checks = packages;
      haskellProject.extraDevPackages = [ pkgs.python3 pkgs.openssl ];
    };
}
