-- | Safe, structured errors. Paths identify definitions, never SQL contents.
module ClickHouseMigrate.Error
  ( DefinitionError (..),
    DefinitionErrorCode (..),
    PlanError (..),
    PlanErrorCode (..),
  )
where

import ClickHouseMigrate.Prelude

data DefinitionErrorCode
  = InvalidName
  | EmptyCollection
  | DuplicateName
  | InvalidUtf8
  | NulInSql
  | EmptySql
  | UnterminatedSql
  | MultipleStatements
  | UnsupportedSql
  | ProtectedSetting
  | UnknownChecksumFormat
  deriving stock (Eq, Ord, Show)

-- | Offset, when present, is zero-based Unicode character offset in SQL.
data DefinitionError = DefinitionError
  { code :: !DefinitionErrorCode,
    path :: ![Text],
    characterOffset :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data PlanErrorCode
  = EmptyPlan
  | DuplicateComponent
  | MissingDependency
  | SelfDependency
  | DependencyCycle
  | EmptySchedule
  | UnknownScheduledMigration
  | DuplicateScheduledMigration
  | MissingScheduledMigration
  | MigrationOrderChanged
  | DependencyNotActivated
  | DependencyAfterDependent
  deriving stock (Eq, Ord, Show)

data PlanError = PlanError
  { code :: !PlanErrorCode,
    components :: ![Text]
  }
  deriving stock (Eq, Show)
