-- | Order-preserving validated plans and immutable context-bound views.
module ClickHouseMigrate.Plan
  ( MigrationPlan,
    migrationPlan,
    migrationPlanFromList,
    scheduledMigrationPlan,
    scheduledMigrationPlanFromList,
    inspectSchedule,
    inspectPlan,
    ComponentView,
    componentViewName,
    componentDependencies,
    componentMigrations,
    MigrationView,
    migrationId,
    migrationDescription,
    migrationSteps,
    migrationChecksum,
    StepView,
    stepViewName,
    stepSql,
    stepChecksum,
    StepChecksum,
    MigrationChecksum,
    ChecksumFormat (ChecksumV1),
    checksumFormatName,
    parseChecksumFormat,
    stepChecksumFormat,
    migrationChecksumFormat,
    stepChecksumHex,
    migrationChecksumHex,
    completionPolicy,
  )
where

import ClickHouseMigrate.Definition
import ClickHouseMigrate.Error
import ClickHouseMigrate.Internal.Checksum qualified as Checksum
import ClickHouseMigrate.Internal.Types
import ClickHouseMigrate.Prelude
import Control.Monad (foldM)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

migrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
migrationPlan components = do
  let ordered = NE.toList components
      names = [name | MigrationComponent name _ _ <- ordered]
      allNames = Set.fromList names
      graph = Map.fromList [(name, deps) | MigrationComponent name deps _ <- ordered]
      bad c xs = Left (PlanError c (map componentNameText xs))
  if Set.size allNames /= length names then bad DuplicateComponent names else pure ()
  mapM_
    ( \(MigrationComponent name deps _) ->
        if Set.member name deps
          then bad SelfDependency [name]
          else case Set.toAscList (Set.difference deps allNames) of
            [] -> Right ()
            missing -> bad MissingDependency (name : missing)
    )
    ordered
  case cyclicRemainder graph of
    [] -> pure ()
    remaining -> bad DependencyCycle remaining
  let positions = Map.fromList (zip names [0 :: Int ..])
  mapM_
    ( \(MigrationComponent name deps _) ->
        case [dep | dep <- Set.toAscList deps, Map.lookup dep positions >= Map.lookup name positions] of
          [] -> Right ()
          late -> bad DependencyAfterDependent (name : late)
    )
    ordered
  let catalog = fmap bindComponent components
  pure (MigrationPlan catalog (catalog >>= componentMigrations))

-- | Parsing boundary for application formats which represent empty lists.
migrationPlanFromList :: [MigrationComponent] -> Either PlanError MigrationPlan
migrationPlanFromList = maybe (Left (PlanError EmptyPlan [])) migrationPlan . NE.nonEmpty

-- | Complete application-owned order. Dependencies constrain first activation;
-- later upgrades follow the explicit schedule, retaining each library's order.
scheduledMigrationPlan :: NonEmpty MigrationComponent -> NonEmpty MigrationId -> Either PlanError MigrationPlan
scheduledMigrationPlan components schedule = do
  ordinary <- migrationPlan components
  let catalog = inspectPlan ordinary
      authored = NE.toList (inspectSchedule ordinary)
      byId = Map.fromList [(migrationId view, view) | view <- authored]
      ids = NE.toList schedule
      named identity = [componentNameText (migrationIdComponent identity), migrationNameText (migrationIdName identity)]
      reject kind identity = Left (PlanError kind (named identity))
  resolved <- traverse (\identity -> maybe (reject UnknownScheduledMigration identity) Right (Map.lookup identity byId)) schedule
  _ <- foldM (\seen identity -> if Set.member identity seen then reject DuplicateScheduledMigration identity else Right (Set.insert identity seen)) Set.empty ids
  mapM_ (\view -> unless (migrationId view `elem` ids) (reject MissingScheduledMigration (migrationId view))) authored
  mapM_
    ( \component -> do
        let name = componentViewName component
            local = filter ((== name) . migrationIdComponent) ids
        unless (local == map migrationId (NE.toList (componentMigrations component))) (Left (PlanError MigrationOrderChanged [componentNameText name]))
    )
    catalog
  let dependencies = Map.fromList [(componentViewName c, componentDependencies c) | c <- NE.toList catalog]
  _ <-
    foldM
      ( \active identity -> do
          let name = migrationIdComponent identity
              missing = Map.findWithDefault Set.empty name dependencies `Set.difference` active
          unless (Set.member name active || Set.null missing) (Left (PlanError DependencyNotActivated (map componentNameText (name : Set.toAscList missing))))
          Right (Set.insert name active)
      )
      Set.empty
      ids
  pure (MigrationPlan catalog resolved)

scheduledMigrationPlanFromList :: [MigrationComponent] -> [MigrationId] -> Either PlanError MigrationPlan
scheduledMigrationPlanFromList components schedule = do
  catalog <- maybe (Left (PlanError EmptyPlan [])) Right (NE.nonEmpty components)
  order <- maybe (Left (PlanError EmptySchedule [])) Right (NE.nonEmpty schedule)
  scheduledMigrationPlan catalog order

inspectSchedule :: MigrationPlan -> NonEmpty MigrationView
inspectSchedule (MigrationPlan _ schedule) = schedule

cyclicRemainder :: Map.Map ComponentName (Set ComponentName) -> [ComponentName]
cyclicRemainder graph
  | Map.null graph = []
  | Map.null ready = Map.keys graph
  | otherwise = cyclicRemainder (Map.map (`Set.difference` Map.keysSet ready) waiting)
  where
    (ready, waiting) = Map.partition Set.null graph

bindComponent :: MigrationComponent -> ComponentView
bindComponent (MigrationComponent component deps migrations) = ComponentView component deps (fmap bindMigration migrations)
  where
    bindMigration (Migration name description steps) =
      let encodings = fmap (encodeStep name) steps
          boundSteps = NE.zipWith (\(SqlStep step sql) encoded -> StepView step sql (StepChecksum (Checksum.digest encoded))) steps encodings
          checksum = MigrationChecksum (Checksum.digest (Checksum.encodeMigrationV1 (componentNameText component) (migrationNameText name) (NE.toList encodings)))
       in MigrationView (MigrationId component name) description boundSteps checksum
    encodeStep migration (SqlStep step sql) = Checksum.encodeStepV1 (componentNameText component) (migrationNameText migration) (stepNameText step) sql

inspectPlan :: MigrationPlan -> NonEmpty ComponentView
inspectPlan (MigrationPlan components _) = components

componentViewName :: ComponentView -> ComponentName
componentViewName (ComponentView name _ _) = name

componentDependencies :: ComponentView -> Set ComponentName
componentDependencies (ComponentView _ deps _) = deps

componentMigrations :: ComponentView -> NonEmpty MigrationView
componentMigrations (ComponentView _ _ migrations) = migrations

migrationId :: MigrationView -> MigrationId
migrationId (MigrationView identity _ _ _) = identity

migrationDescription :: MigrationView -> Maybe Text
migrationDescription (MigrationView _ description _ _) = description

migrationSteps :: MigrationView -> NonEmpty StepView
migrationSteps (MigrationView _ _ steps _) = steps

migrationChecksum :: MigrationView -> MigrationChecksum
migrationChecksum (MigrationView _ _ _ checksum) = checksum

stepViewName :: StepView -> StepName
stepViewName (StepView name _ _) = name

stepSql :: StepView -> ByteString
stepSql (StepView _ sql _) = sql

stepChecksum :: StepView -> StepChecksum
stepChecksum (StepView _ _ checksum) = checksum

checksumFormatName :: ChecksumFormat -> Text
checksumFormatName ChecksumV1 = "sha256-v1"

parseChecksumFormat :: Text -> Either DefinitionError ChecksumFormat
parseChecksumFormat "sha256-v1" = Right ChecksumV1
parseChecksumFormat _ = Left (DefinitionError UnknownChecksumFormat ["checksum", "format"] Nothing)

stepChecksumFormat :: StepChecksum -> ChecksumFormat
stepChecksumFormat _ = ChecksumV1

migrationChecksumFormat :: MigrationChecksum -> ChecksumFormat
migrationChecksumFormat _ = ChecksumV1

stepChecksumHex :: StepChecksum -> Text
stepChecksumHex (StepChecksum bytes) = Checksum.digestHex bytes

migrationChecksumHex :: MigrationChecksum -> Text
migrationChecksumHex (MigrationChecksum bytes) = Checksum.digestHex bytes

completionPolicy :: ByteString
completionPolicy = Checksum.completionPolicyV1
