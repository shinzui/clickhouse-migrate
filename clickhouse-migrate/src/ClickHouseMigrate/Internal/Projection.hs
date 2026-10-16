-- | Pure immutable history fold. No timestamp or merge order chooses a winner.
module ClickHouseMigrate.Internal.Projection (project, appendProjection, comparePlan, unresolved, resolvedStep) where

import ClickHouseMigrate.Internal.LedgerCodec (contextFor, definitions, definitionsDigest, validateEvent)
import ClickHouseMigrate.Internal.LedgerTypes
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (TargetKey)
import Control.Monad (foldM)
import Data.List (findIndex)
import Data.Map.Strict qualified as Map

project :: TargetKey -> [LedgerEvent] -> Either LedgerError Projection
project _ [] = Left LedgerUninitialized
project target rows = do
  ordered <- deduplicate rows
  case ordered of
    first@(LedgerEvent 1 event ledger _ Nothing _ _ _ Nothing (Initialize actual)) : rest
      | target == actual -> do
          validateEvent first
          foldM appendProjection (Projection (LedgerPosition ledger 1 event) target [] Nothing Nothing [first]) rest
      | otherwise -> Left LedgerIdentityMismatch
    _ -> Left MissingInitialization

-- Equality is byte-equivalent because the strict codec admits only canonical v1
-- bytes. Detect identity conflicts before sorting/collapsing, never take a winner.
deduplicate :: [LedgerEvent] -> Either LedgerError [LedgerEvent]
deduplicate rows = do
  (_, bySequence) <- foldM add (Map.empty, Map.empty) rows
  pure (map snd (Map.toAscList bySequence))
  where
    add (ids, sequences) event@(LedgerEvent sequenceNumber identity _ _ _ _ _ _ _ _) = do
      validateEvent event
      case Map.lookup identity ids of Just old | old /= event -> Left EventIdentityConflict; _ -> Right ()
      case Map.lookup sequenceNumber sequences of Just old | old /= event -> Left SequenceConflict; _ -> Right ()
      pure (Map.insert identity event ids, Map.insert sequenceNumber event sequences)

appendProjection :: Projection -> LedgerEvent -> Either LedgerError Projection
appendProjection state event@(LedgerEvent sequenceNumber identity ledger _ attempt _ _ _ context body) = do
  validateEvent event
  let LedgerPosition expected previous _ = position state
  require LedgerIdentityMismatch (ledger == expected)
  require SequenceGap (previous < maxBound && sequenceNumber == previous + 1)
  require EventIdentityConflict (all ((/= identity) . eventId) (events state))
  case body of
    StartMigration _ -> pure ()
    AuthorizeRecovery _ -> pure ()
    _ -> case attempt of
      Nothing -> pure ()
      Just current -> require ImpossibleTransition (all (\old -> runId old == runId event) [old | old <- events state, attemptId old == Just current])
  expectedContext <- case body of
    StartMigration definition -> Just <$> contextFor definition Nothing
    AdoptEntry definition _ -> Just <$> contextFor definition Nothing
    Initialize _ -> pure Nothing
    StartAdoption _ -> pure Nothing
    CompleteAdoption _ -> pure Nothing
    _ -> do
      (definition, _, _, _) <- getActive state
      let index = case body of
            StartStep i _ -> Just i
            SucceedStep i _ -> Just i
            FailStep i _ _ -> Just i
            AcceptCompletion i _ -> Just i
            AuthorizeRecovery (Recovery action _ _ _ _) -> case action of RetryStep i -> Just i; AcceptStep i -> Just i; _ -> Nothing
            _ -> Nothing
      Just <$> contextFor definition index
  require DefinitionMismatch (context == expectedContext)
  next <- transition state attempt body
  pure next {position = LedgerPosition ledger sequenceNumber identity, events = events state ++ [event]}

transition :: Projection -> Maybe Text -> EventBody -> Either LedgerError Projection
transition state attempt body = case body of
  Initialize _ -> Left ImpossibleTransition
  StartMigration definition -> do
    require UnresolvedHistory (isNothing (active state) && isNothing (adoption state))
    require DefinitionMismatch (ordinal definition == length (completed state))
    current <- maybe (Left ImpossibleTransition) Right attempt
    require EventIdentityConflict (current `notElem` allAttempts state)
    require DefinitionMismatch (all (\(RecordedMigration old _ _) -> (component old, migration old) /= (component definition, migration definition)) (completed state))
    pure state {active = Just (ActiveMigration definition current (replicate (length (steps definition)) NeverStarted) Nothing)}
  StartStep index query -> withActive state attempt $ \definition current checkpoints authorization -> do
    require ImpossibleTransition (nextUnresolved checkpoints == Just index && at index checkpoints == Just NeverStarted && query `notElem` allQueries state)
    require ImpossibleTransition (case authorization of Nothing -> True; Just Resume -> True; Just (RetryStep wanted) -> wanted == index; _ -> False)
    pure (ActiveMigration definition current (replace index (Started query) checkpoints) Nothing)
  SucceedStep index query -> withActive state attempt $ \definition current checkpoints authorization -> do
    require ImpossibleTransition (at index checkpoints == Just (Started query) && isNothing authorization)
    pure (ActiveMigration definition current (replace index (Succeeded query) checkpoints) Nothing)
  FailStep index query failure -> withActive state attempt $ \definition current checkpoints authorization -> do
    require ImpossibleTransition (at index checkpoints == Just (Started query) && isNothing authorization)
    pure (ActiveMigration definition current (replace index (Failed query failure) checkpoints) Nothing)
  CompleteMigration -> do
    (definition, current, checkpoints, authorization) <- getActive state
    require ImpossibleTransition (attempt == Just current && all resolvedStep checkpoints && (isNothing authorization || authorization == Just Finalize))
    pure state {completed = completed state ++ [RecordedMigration definition Applied checkpoints], active = Nothing}
  AuthorizeRecovery (Recovery action expected previous next (QuiescenceEvidence target _)) -> do
    (definition, current, checkpoints, _) <- getActive state
    require StaleLedgerState (expected == position state && previous == current && attempt == Just next)
    require LedgerIdentityMismatch (target == targetOf state)
    require EventIdentityConflict (next `notElem` allAttempts state)
    let unfinished = nextUnresolved checkpoints
        uncertain step = case at step checkpoints of Just (Started _) -> True; Just (Failed _ _) -> True; _ -> False
    case action of
      Resume -> require ImpossibleTransition (not (all resolvedStep checkpoints) && all (\step -> resolvedStep step || step == NeverStarted) checkpoints)
      RetryStep step -> require ImpossibleTransition (unfinished == Just step && uncertain step)
      AcceptStep step -> require ImpossibleTransition (unfinished == Just step && uncertain step)
      Finalize -> require ImpossibleTransition (all resolvedStep checkpoints)
    let revised = case action of RetryStep step -> replace step NeverStarted checkpoints; _ -> checkpoints
    pure state {active = Just (ActiveMigration definition next revised (Just action))}
  AcceptCompletion index evidence -> withActive state attempt $ \definition current checkpoints authorization -> do
    require ImpossibleTransition (authorization == Just (AcceptStep index) && nextUnresolved checkpoints == Just index)
    pure (ActiveMigration definition current (replace index (Accepted evidence) checkpoints) Nothing)
  StartAdoption batch@(AdoptionBatch _ _ _ _ count) -> do
    require ImpossibleTransition (null (completed state) && isNothing (active state) && isNothing (adoption state) && count > 0 && isNothing attempt)
    -- Adoption is a fresh-ledger batch, not a second import after a completed batch.
    require ImpossibleTransition (all (\event -> case bodyOf event of StartAdoption _ -> False; _ -> True) (events state))
    pure state {adoption = Just (ActiveAdoption batch [])}
  AdoptEntry definition evidence -> case adoption state of
    Nothing -> Left ImpossibleTransition
    Just (ActiveAdoption batch@(AdoptionBatch _ _ _ _ count) entries) -> do
      require ImpossibleTransition (isNothing attempt && length entries < count && ordinal definition == length entries)
      require DefinitionMismatch (all (\(RecordedMigration old _ _) -> (component old, migration old) /= (component definition, migration definition)) entries)
      pure state {adoption = Just (ActiveAdoption batch (entries ++ [RecordedMigration definition Adopted (replicate (length (steps definition)) (Accepted evidence))]))}
  CompleteAdoption digest -> case adoption state of
    Nothing -> Left ImpossibleTransition
    Just (ActiveAdoption (AdoptionBatch _ _ mapping definitionsHash count) entries) -> do
      require ImpossibleTransition (isNothing attempt && count == length entries && digest == mapping && definitionsDigest [definition | RecordedMigration definition _ _ <- entries] == definitionsHash)
      pure state {completed = entries, adoption = Nothing}
  where
    targetOf (Projection _ target _ _ _ _) = target
    bodyOf (LedgerEvent _ _ _ _ _ _ _ _ _ value) = value

withActive :: Projection -> Maybe Text -> (Definition -> Text -> [StepState] -> Maybe RecoveryAction -> Either LedgerError ActiveMigration) -> Either LedgerError Projection
withActive state attempt action = do
  (definition, current, checkpoints, authorization) <- getActive state
  require ImpossibleTransition (attempt == Just current)
  changed <- action definition current checkpoints authorization
  pure state {active = Just changed}

getActive :: Projection -> Either LedgerError (Definition, Text, [StepState], Maybe RecoveryAction)
getActive state = case (active state, adoption state) of
  (Just (ActiveMigration definition attempt checkpoints authorization), Nothing) -> Right (definition, attempt, checkpoints, authorization)
  _ -> Left ImpossibleTransition

comparePlan :: MigrationPlan -> Projection -> Either LedgerError ()
comparePlan plan state = do
  let supplied = definitions plan
      recorded =
        [definition | RecordedMigration definition _ _ <- completed state]
          ++ [definition | Just (ActiveMigration definition _ _ _) <- [active state]]
          ++ concat [[definition | RecordedMigration definition _ _ <- entries] | Just (ActiveAdoption _ entries) <- [adoption state]]
  require DefinitionMismatch (recorded == take (length recorded) supplied)

unresolved :: Projection -> Bool
unresolved state = isJust (active state) || isJust (adoption state)

resolvedStep :: StepState -> Bool
resolvedStep (Succeeded _) = True
resolvedStep (Accepted _) = True
resolvedStep _ = False

nextUnresolved :: [StepState] -> Maybe Int
nextUnresolved = findIndex (not . resolvedStep)

at :: Int -> [a] -> Maybe a
at index values
  | index < 0 = Nothing
  | otherwise = case drop index values of value : _ -> Just value; _ -> Nothing

replace :: Int -> a -> [a] -> [a]
replace index value values = take index values ++ [value] ++ drop (index + 1) values

allAttempts :: Projection -> [Text]
allAttempts = concatMap (\event -> case body event of StartMigration _ -> maybe [] pure (attemptId event); AuthorizeRecovery (Recovery _ _ _ next _) -> [next]; _ -> []) . events

allQueries :: Projection -> [Text]
allQueries = concatMap (\event -> case body event of StartStep _ query -> [query]; _ -> []) . events

require :: LedgerError -> Bool -> Either LedgerError ()
require _ True = Right ()
require failure False = Left failure
