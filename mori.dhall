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
    , standards = [ "mori://shinzui/haskell-jitsurei" ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "user-documentation"
        , path = "docs/user"
        , profile = Some "mori/user-documentation-profile.dhall"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "mori://shinzui/okf-profiles"
                , publisherRef = Some Schema.MoriRef::{
                  , namespace = "shinzui"
                  , name = "okf-profiles"
                  }
                , export = Some "documentation.userDocumentation"
                , version = Some "v0.21.0"
                , pin = Some
                    "sha256:4be32588d55c74282ceab54b06b22f552cdbf4215788e3eb5256ee8744cb92a2"
                }
            )
        , okfVersion = "0.2"
        , description = Some
            "User guides, operational runbooks, and versioned interface references"
        }
      , Schema.OkfBundle::{
        , name = "reviews"
        , path = "docs/reviews"
        , profile = Some "mori/reviews-profile.dhall"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "mori://shinzui/okf-profiles"
                , publisherRef = Some Schema.MoriRef::{
                  , namespace = "shinzui"
                  , name = "okf-profiles"
                  }
                , export = Some "assurance.reviews"
                , version = Some "v0.21.0"
                , pin = Some
                    "sha256:4be32588d55c74282ceab54b06b22f552cdbf4215788e3eb5256ee8744cb92a2"
                }
            )
        , okfVersion = "0.2"
        , description = Some
            "Implementation reviews with scoped findings and remediation evidence"
        }
      ]
    , packages =
      [ Schema.Package::{
        , name = "clickhouse-migrate"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate"
        , dependencies =
          [ Schema.Dependency.ByName "bytestring"
          , Schema.Dependency.ByName "text"
          , Schema.Dependency.ByName "containers"
          , Schema.Dependency.ByName "cryptohash-sha256"
          ]
        }
      , Schema.Package::{
        , name = "clickhouse-migrate-embed"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate-embed"
        , dependencies =
          [ Schema.Dependency.ByName "clickhouse-migrate"
          , Schema.Dependency.ByName "aeson"
          , Schema.Dependency.ByName "bytestring"
          , Schema.Dependency.ByName "text"
          , Schema.Dependency.ByName "containers"
          , Schema.Dependency.ByName "directory"
          , Schema.Dependency.ByName "filepath"
          , Schema.Dependency.ByName "template-haskell"
          , Schema.Dependency.ByName "process"
          , Schema.Dependency.ByName "cryptohash-sha256"
          ]
        }
      , Schema.Package::{
        , name = "clickhouse-migrate-cli"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate-cli"
        , dependencies = [ Schema.Dependency.ByName "clickhouse-migrate" ]
        }
      , Schema.Package::{
        , name = "clickhouse-migrate-test-support"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "clickhouse-migrate-test-support"
        , dependencies = [ Schema.Dependency.ByName "clickhouse-migrate" ]
        }
      ]
    }
