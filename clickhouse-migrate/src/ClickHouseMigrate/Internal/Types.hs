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

data MigrationPlan = MigrationPlan !(NonEmpty ComponentView) !(NonEmpty MigrationView) deriving stock (Eq)

data ChecksumFormat = ChecksumV1 | ChecksumV2 deriving stock (Eq, Ord, Show)

data StepChecksum = StepChecksum !ByteString | StepChecksumV2 !ByteString deriving stock (Eq, Ord)

data MigrationChecksum = MigrationChecksum !ByteString | MigrationChecksumV2 !ByteString deriving stock (Eq, Ord)

data ComponentView = ComponentView !ComponentName !(Set ComponentName) !(NonEmpty MigrationView) deriving stock (Eq)

data MigrationView = MigrationView !MigrationId !(Maybe Text) !(NonEmpty StepView) !MigrationChecksum !MigrationChecksum deriving stock (Eq)

data StepView = StepView !StepName !ByteString !StepChecksum !StepChecksum deriving stock (Eq)
