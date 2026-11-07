{-# LANGUAGE TemplateHaskell #-}

module Example.Catalog.Replicated (component) where

import ClickHouseMigrate (MigrationComponent)
import ClickHouseMigrate.Embed (embedComponent)

component :: MigrationComponent
component = $(embedComponent "migrations-replicated/manifest.json")
