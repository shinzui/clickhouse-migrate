module Optic where

import ClickHouseMigrate
import Data.ByteString (ByteString)
import Data.Functor.Identity (Identity (..))

set :: ((a -> Identity a) -> s -> Identity s) -> a -> s -> s
set optic value source = runIdentity (optic (const (Identity value)) source)

forge :: ByteString -> StepView -> StepView
forge = set stepSql
