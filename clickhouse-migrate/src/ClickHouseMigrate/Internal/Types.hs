-- | Private representation. Public modules export types and read-only functions.
module ClickHouseMigrate.Internal.Types where

import ClickHouseMigrate.Prelude

-- Use data, not newtype: Coercible must not bypass validation.
data ComponentName = ComponentName !Text deriving stock (Eq, Ord, Show)

data MigrationName = MigrationName !Text deriving stock (Eq, Ord, Show)

data StepName = StepName !Text deriving stock (Eq, Ord, Show)

data MigrationId = MigrationId !ComponentName !MigrationName deriving stock (Eq, Ord, Show)

data SqlStep = SqlStep !StepName !ByteString deriving stock (Eq)

data Migration = Migration !MigrationName !(Maybe Text) !(NonEmpty SqlStep) deriving stock (Eq)

data MigrationComponent = MigrationComponent !ComponentName !(Set ComponentName) !(NonEmpty Migration) deriving stock (Eq)

data MigrationPlan = MigrationPlan !(NonEmpty ComponentView) deriving stock (Eq)

data ChecksumFormat = ChecksumV1 deriving stock (Eq, Ord, Show)

data StepChecksum = StepChecksum !ByteString deriving stock (Eq, Ord)

data MigrationChecksum = MigrationChecksum !ByteString deriving stock (Eq, Ord)

data ComponentView = ComponentView !ComponentName !(Set ComponentName) !(NonEmpty MigrationView) deriving stock (Eq)

data MigrationView = MigrationView !MigrationId !(Maybe Text) !(NonEmpty StepView) !MigrationChecksum deriving stock (Eq)

data StepView = StepView !StepName !ByteString !StepChecksum deriving stock (Eq)
