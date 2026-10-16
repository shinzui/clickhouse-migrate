let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/3522f4a51181d73c9c90fc27a7c0838bd29ae95f/package.dhall
        sha256:dcb19e2312e790bad14e622cc98a1281cd2298c5b564a2f0d0534d3c718d8803

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "clickhouse-migrate"
      , namespace = "shinzui"
      , stableId = Some "project_01m51fy3yvep481xpr8vrcj8p3"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some "Haskell migration toolkit for ClickHouse"
      }
    , repos =
      [ Schema.Repo::{
        , name = "clickhouse-migrate"
        , github = Some "shinzui/clickhouse-migrate"
        }
      ]
    , packages =
      [ Schema.Package::{
        , name = "clickhouse-migrate"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate"
        }
      , Schema.Package::{
        , name = "clickhouse-migrate-embed"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate-embed"
        }
      , Schema.Package::{
        , name = "clickhouse-migrate-cli"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate-cli"
        }
      , Schema.Package::{
        , name = "clickhouse-migrate-test-support"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate-test-support"
        }
      ]
    }
