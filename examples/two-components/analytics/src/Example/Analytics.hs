{-# LANGUAGE TemplateHaskell #-}

-- | This library owns its names, order, manifest and exact SQL bytes.
module Example.Analytics (component) where

import ClickHouseMigrate (MigrationComponent)
import ClickHouseMigrate.Embed (embedComponent)

component :: MigrationComponent
component = $(embedComponent "migrations/manifest.json")
