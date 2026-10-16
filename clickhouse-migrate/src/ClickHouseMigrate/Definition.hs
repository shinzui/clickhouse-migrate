-- | Pure authoring values. Constructors and representations remain private.
module ClickHouseMigrate.Definition
  ( ComponentName,
    MigrationName,
    StepName,
    MigrationId,
    SqlStep,
    Migration,
    MigrationComponent,
    componentName,
    migrationName,
    stepName,
    componentNameText,
    migrationNameText,
    stepNameText,
    migrationIdFromNames,
    migrationIdComponent,
    migrationIdName,
    sqlStep,
    sqlMigration,
    migrationComponent,
    withMigrationDescription,
    sqlMigrationFromList,
    migrationComponentFromList,
  )
where

import ClickHouseMigrate.Error
import ClickHouseMigrate.Internal.SqlEnvelope (validateSql)
import ClickHouseMigrate.Internal.Types
import ClickHouseMigrate.Prelude
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as Text

validateName :: Text -> Text -> Either DefinitionError Text
validateName scope value
  | Text.length value <= 128 && maybe False (\(c, rest) -> first c && Text.all later rest) (Text.uncons value) = Right value
  | otherwise = Left (DefinitionError InvalidName [scope] Nothing)
  where
    first c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    later c = first c || c == '_' || c == '-'

componentName :: Text -> Either DefinitionError ComponentName
componentName = fmap ComponentName . validateName "component"

migrationName :: Text -> Either DefinitionError MigrationName
migrationName = fmap MigrationName . validateName "migration"

stepName :: Text -> Either DefinitionError StepName
stepName = fmap StepName . validateName "step"

componentNameText :: ComponentName -> Text
componentNameText (ComponentName value) = value

migrationNameText :: MigrationName -> Text
migrationNameText (MigrationName value) = value

stepNameText :: StepName -> Text
stepNameText (StepName value) = value

-- | A schedule identity from already validated local names.
migrationIdFromNames :: ComponentName -> MigrationName -> MigrationId
migrationIdFromNames = MigrationId

migrationIdComponent :: MigrationId -> ComponentName
migrationIdComponent (MigrationId component _) = component

migrationIdName :: MigrationId -> MigrationName
migrationIdName (MigrationId _ name) = name

sqlStep :: Text -> ByteString -> Either DefinitionError SqlStep
sqlStep name sql = do
  validated <- stepName name
  case validateSql sql of
    Left (DefinitionError c path offset) -> Left (DefinitionError c (["step", name] ++ path) offset)
    Right () -> Right (SqlStep validated sql)

sqlMigration :: Text -> NonEmpty SqlStep -> Either DefinitionError Migration
sqlMigration name steps = do
  validated <- migrationName name
  unique ["migration", name, "steps"] [step | SqlStep step _ <- NE.toList steps]
  pure (Migration validated Nothing steps)

-- | Parsing boundary for formats which can represent empty lists.
sqlMigrationFromList :: Text -> [SqlStep] -> Either DefinitionError Migration
sqlMigrationFromList name steps = nonEmpty ["migration", name, "steps"] steps >>= sqlMigration name

withMigrationDescription :: Maybe Text -> Migration -> Migration
withMigrationDescription description (Migration name _ steps) = Migration name description steps

migrationComponent :: Text -> Set Text -> NonEmpty Migration -> Either DefinitionError MigrationComponent
migrationComponent name dependencies migrations = do
  validated <- componentName name
  deps <- Set.fromList <$> traverse componentName (Set.toAscList dependencies)
  unique ["component", name, "migrations"] [migration | Migration migration _ _ <- NE.toList migrations]
  pure (MigrationComponent validated deps migrations)

migrationComponentFromList :: Text -> Set Text -> [Migration] -> Either DefinitionError MigrationComponent
migrationComponentFromList name deps migrations = nonEmpty ["component", name, "migrations"] migrations >>= migrationComponent name deps

nonEmpty :: [Text] -> [a] -> Either DefinitionError (NonEmpty a)
nonEmpty path = maybe (Left (DefinitionError EmptyCollection path Nothing)) Right . NE.nonEmpty

unique :: (Ord a) => [Text] -> [a] -> Either DefinitionError ()
unique path names
  | Set.size (Set.fromList names) == length names = Right ()
  | otherwise = Left (DefinitionError DuplicateName path Nothing)
