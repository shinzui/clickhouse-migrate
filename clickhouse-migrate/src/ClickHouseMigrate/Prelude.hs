{-# LANGUAGE PackageImports #-}

-- | Small project prelude. Extend this as shared dependencies are introduced.
module ClickHouseMigrate.Prelude (module X) where

import "base" Control.Monad as X (unless, void, when)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)

import "bytestring" Data.ByteString as X (ByteString)
import "containers" Data.Set as X (Set)
import "text" Data.Text as X (Text)
