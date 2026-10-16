-- | Strict bounded version-one event codec; values are JSON data, never SQL.
module ClickHouseMigrate.Internal.LedgerCodec
  ( encodeEvent,
    decodeEvent,
    eventValue,
    definitionValue,
    definitions,
    validateEvent,
    eventKind,
    encodeValue,
    definitionsDigest,
    contextFor,
  )
where

import ClickHouseMigrate.Definition qualified as Def
import ClickHouseMigrate.Internal.Checksum qualified as Checksum
import ClickHouseMigrate.Internal.LedgerTypes
import ClickHouseMigrate.Internal.LedgerValidation (auditContext, ledgerPositionText, parseLedgerPosition)
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target qualified as Target
import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, withObject, (.:))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (UTCTime, defaultTimeLocale, parseTimeM)

encodeValue :: Value -> ByteString
encodeValue = \case
  Object members -> "{" <> BS.intercalate "," [encodeValue (String (Key.toText key)) <> ":" <> encodeValue value | (key, value) <- sortOn (Key.toText . fst) (KM.toList members)] <> "}"
  Array values -> "[" <> BS.intercalate "," (foldr (\value rest -> encodeValue value : rest) [] values) <> "]"
  scalar -> Lazy.toStrict (Aeson.encode scalar)

encodeEvent :: LedgerEvent -> ByteString
encodeEvent = encodeValue . eventValue

eventValue :: LedgerEvent -> Value
eventValue (LedgerEvent sequenceNumber event ledger run attempt time audit runner context body) =
  object
    [ "version" .= (1 :: Int),
      "sequence" .= sequenceNumber,
      "eventId" .= event,
      "ledgerId" .= Target.ledgerIdText ledger,
      "runId" .= run,
      "attemptId" .= attempt,
      "occurredAt" .= time,
      "audit" .= auditValue audit,
      "runnerVersion" .= runner,
      "context" .= fmap contextValue context,
      "kind" .= eventKind body,
      "body" .= bodyValue body
    ]

eventKind :: EventBody -> Text
eventKind = \case
  Initialize _ -> "initialized"
  StartMigration _ -> "migration-started"
  StartStep _ _ -> "step-started"
  SucceedStep _ _ -> "step-succeeded"
  FailStep _ _ _ -> "execution-failed"
  CompleteMigration -> "migration-completed"
  AuthorizeRecovery _ -> "recovery-authorized"
  AcceptCompletion _ _ -> "step-accepted"
  StartAdoption _ -> "adoption-started"
  AdoptEntry _ _ -> "adoption-entry"
  CompleteAdoption _ -> "adoption-completed"

bodyValue :: EventBody -> Value
bodyValue = \case
  Initialize target -> object ["target" .= Target.targetKeyText target, "schemaVersion" .= (1 :: Int), "checksumFormat" .= ("sha256-v1" :: Text), "policy" .= Encoding.decodeUtf8 Plan.completionPolicy]
  StartMigration definition -> definitionValue definition
  StartStep step query -> stepValue step query
  SucceedStep step query -> stepValue step query
  FailStep step query (FailureEvidence code status server) -> object ["step" .= step, "queryId" .= query, "code" .= code, "httpStatus" .= status, "serverCode" .= server]
  CompleteMigration -> object []
  AuthorizeRecovery (Recovery action expected previous next (QuiescenceEvidence target audit)) ->
    object
      [ "action" .= recoveryName action,
        "step" .= recoveryStep action,
        "expected" .= ledgerPositionText expected,
        "previousAttempt" .= previous,
        "nextAttempt" .= next,
        "target" .= Target.targetKeyText target,
        "quiescence" .= auditValue audit
      ]
  AcceptCompletion step evidence -> object ["step" .= step, "evidence" .= evidenceValue evidence]
  StartAdoption (AdoptionBatch source snapshot mapping definitionsHash count) ->
    object
      ["source" .= source, "snapshot" .= snapshot, "mapping" .= mapping, "definitions" .= definitionsHash, "count" .= count]
  AdoptEntry definition evidence -> object ["definition" .= definitionValue definition, "evidence" .= evidenceValue evidence]
  CompleteAdoption digest -> object ["digest" .= digest]

stepValue :: Int -> Text -> Value
stepValue step query = object ["step" .= step, "queryId" .= query]

auditValue :: AuditContext -> Value
auditValue (AuditContext actor reason references) = object ["actor" .= actor, "reason" .= reason, "references" .= references]

evidenceValue :: Evidence -> Value
evidenceValue (Evidence level references) = object ["level" .= (case level of OperatorAttestation -> "operator-attestation" :: Text; PredecessorChecksum -> "predecessor-checksum"), "references" .= references]

definitionValue :: Definition -> Value
definitionValue (Definition ordinal componentIndex component dependencies migration checksum steps) =
  object
    [ "ordinal" .= ordinal,
      "componentIndex" .= componentIndex,
      "component" .= component,
      "dependencies" .= dependencies,
      "migration" .= migration,
      "checksum" .= checksum,
      "steps" .= [object ["name" .= name, "checksum" .= digest] | StepDefinition name digest <- steps]
    ]

contextValue :: EventContext -> Value
contextValue (EventContext component migration checksum step) =
  object
    [ "component" .= component,
      "migration" .= migration,
      "checksum" .= checksum,
      "step" .= fmap (\(name, digest) -> object ["name" .= name, "checksum" .= digest]) step
    ]

contextFor :: Definition -> Maybe Int -> Either LedgerError EventContext
contextFor definition index =
  EventContext (component definition) (migration definition) (checksum definition) <$> case index of
    Nothing -> Right Nothing
    Just i | i >= 0 -> case drop i (steps definition) of
      StepDefinition name digest : _ -> Right (Just (name, digest))
      _ -> Left InvalidEvent
    _ -> Left InvalidEvent

parseContext :: Value -> Parser EventContext
parseContext = exact ["component", "migration", "checksum", "step"] $ \o ->
  EventContext <$> o .: "component" <*> o .: "migration" <*> o .: "checksum" <*> (o .: "step" >>= traverse (exact ["name", "checksum"] (\s -> (,) <$> s .: "name" <*> s .: "checksum")))

recoveryName :: RecoveryAction -> Text
recoveryName = \case Resume -> "resume"; RetryStep _ -> "retry-step"; AcceptStep _ -> "accept-step"; Finalize -> "finalize"

recoveryStep :: RecoveryAction -> Maybe Int
recoveryStep = \case RetryStep step -> Just step; AcceptStep step -> Just step; _ -> Nothing

definitions :: Plan.MigrationPlan -> [Definition]
definitions plan = zipWith bind [0 ..] [(index, component, migration) | (index, component) <- zip [0 ..] (NE.toList (Plan.inspectPlan plan)), migration <- NE.toList (Plan.componentMigrations component)]
  where
    bind ordinal (index, component, migration) =
      Definition
        ordinal
        index
        (Def.componentNameText (Plan.componentViewName component))
        (map Def.componentNameText (Set.toAscList (Plan.componentDependencies component)))
        (Def.migrationNameText (Def.migrationIdName (Plan.migrationId migration)))
        (Plan.migrationChecksumHex (Plan.migrationChecksum migration))
        [StepDefinition (Def.stepNameText (Plan.stepViewName step)) (Plan.stepChecksumHex (Plan.stepChecksum step)) | step <- NE.toList (Plan.migrationSteps migration)]

definitionsDigest :: [Definition] -> Text
definitionsDigest values = Checksum.digestHex (Checksum.digest (encodeValue (Aeson.toJSON (map definitionValue values))))

decodeEvent :: ByteString -> Either LedgerError LedgerEvent
decodeEvent bytes
  | BS.length bytes > 65536 = Left LedgerLimitExceeded
  | otherwise = do
      value <- either (const (Left InvalidEvent)) Right (eitherDecodeStrict' bytes)
      event <- either (const (Left InvalidEvent)) Right (parseEither parseEvent value)
      validateEvent event
      -- Our encoder supplies a canonical wire spelling. This also rejects duplicate
      -- keys (including escaped aliases), alternate number/string encodings and
      -- whitespace changes instead of discarding evidence during object decoding.
      if encodeEvent event == bytes then Right event else Left InvalidEvent

parseEvent :: Value -> Parser LedgerEvent
parseEvent = exact ["version", "sequence", "eventId", "ledgerId", "runId", "attemptId", "occurredAt", "audit", "runnerVersion", "context", "kind", "body"] $ \o -> do
  version <- o .: "version" :: Parser Int
  runner <- o .: "runnerVersion" :: Parser Text
  unless (version == 1 && not (Text.null runner) && Text.length runner <= 128) (fail "unsupported version")
  ledger <- o .: "ledgerId" >>= validated Target.ledgerId
  kind <- o .: "kind"
  body <- o .: "body" >>= parseBody kind
  LedgerEvent <$> o .: "sequence" <*> o .: "eventId" <*> pure ledger <*> o .: "runId" <*> o .: "attemptId" <*> o .: "occurredAt" <*> (o .: "audit" >>= parseAudit) <*> pure runner <*> (o .: "context" >>= traverse parseContext) <*> pure body

parseBody :: Text -> Value -> Parser EventBody
parseBody = \case
  "initialized" -> exact ["target", "schemaVersion", "checksumFormat", "policy"] $ \o -> do
    version <- o .: "schemaVersion" :: Parser Int
    format <- o .: "checksumFormat" :: Parser Text
    policy <- o .: "policy" :: Parser Text
    unless (version == 1 && format == "sha256-v1" && policy == Encoding.decodeUtf8 Plan.completionPolicy) (fail "unsupported format")
    Initialize <$> (o .: "target" >>= validated Target.targetKey)
  "migration-started" -> fmap StartMigration . parseDefinition
  "step-started" -> parseStep StartStep
  "step-succeeded" -> parseStep SucceedStep
  "execution-failed" -> exact ["step", "queryId", "code", "httpStatus", "serverCode"] $ \o -> FailStep <$> o .: "step" <*> o .: "queryId" <*> (FailureEvidence <$> o .: "code" <*> o .: "httpStatus" <*> o .: "serverCode")
  "migration-completed" -> exact [] (const (pure CompleteMigration))
  "recovery-authorized" -> exact ["action", "step", "expected", "previousAttempt", "nextAttempt", "target", "quiescence"] $ \o -> do
    name <- o .: "action" :: Parser Text
    step <- o .: "step" :: Parser (Maybe Int)
    action <- case (name, step) of
      ("resume", Nothing) -> pure Resume
      ("finalize", Nothing) -> pure Finalize
      ("retry-step", Just i) -> pure (RetryStep i)
      ("accept-step", Just i) -> pure (AcceptStep i)
      _ -> fail "invalid recovery"
    expected <- o .: "expected" >>= validated parseLedgerPosition
    target <- o .: "target" >>= validated Target.targetKey
    audit <- o .: "quiescence" >>= parseAudit
    AuthorizeRecovery <$> (Recovery action expected <$> o .: "previousAttempt" <*> o .: "nextAttempt" <*> pure (QuiescenceEvidence target audit))
  "step-accepted" -> exact ["step", "evidence"] $ \o -> AcceptCompletion <$> o .: "step" <*> (o .: "evidence" >>= parseEvidence)
  "adoption-started" -> exact ["source", "snapshot", "mapping", "definitions", "count"] $ \o -> StartAdoption <$> (AdoptionBatch <$> o .: "source" <*> o .: "snapshot" <*> o .: "mapping" <*> o .: "definitions" <*> o .: "count")
  "adoption-entry" -> exact ["definition", "evidence"] $ \o -> AdoptEntry <$> (o .: "definition" >>= parseDefinition) <*> (o .: "evidence" >>= parseEvidence)
  "adoption-completed" -> exact ["digest"] $ \o -> CompleteAdoption <$> o .: "digest"
  _ -> const (fail "unknown kind")

parseStep :: (Int -> Text -> EventBody) -> Value -> Parser EventBody
parseStep construct = exact ["step", "queryId"] $ \o -> construct <$> o .: "step" <*> o .: "queryId"

parseAudit :: Value -> Parser AuditContext
parseAudit = exact ["actor", "reason", "references"] $ \o -> do
  actor <- o .: "actor"
  reason <- o .: "reason"
  references <- o .: "references"
  validated (\() -> auditContext actor reason references) ()

parseEvidence :: Value -> Parser Evidence
parseEvidence = exact ["level", "references"] $ \o -> do
  level <- o .: "level" :: Parser Text
  Evidence <$> (case level of "operator-attestation" -> pure OperatorAttestation; "predecessor-checksum" -> pure PredecessorChecksum; _ -> fail "unknown evidence") <*> o .: "references"

parseDefinition :: Value -> Parser Definition
parseDefinition = exact ["ordinal", "componentIndex", "component", "dependencies", "migration", "checksum", "steps"] $ \o ->
  Definition <$> o .: "ordinal" <*> o .: "componentIndex" <*> o .: "component" <*> o .: "dependencies" <*> o .: "migration" <*> o .: "checksum" <*> (o .: "steps" >>= mapM (exact ["name", "checksum"] (\s -> StepDefinition <$> s .: "name" <*> s .: "checksum")))

exact :: [Text] -> (Aeson.Object -> Parser a) -> Value -> Parser a
exact keys action = withObject "ledger object" $ \o -> do
  unless (Set.fromList (map Key.toText (KM.keys o)) == Set.fromList keys) (fail "invalid fields")
  action o

validated :: (a -> Either e b) -> a -> Parser b
validated f = either (const (fail "invalid value")) pure . f

validateEvent :: LedgerEvent -> Either LedgerError ()
validateEvent event@(LedgerEvent sequenceNumber eventId ledger run attempt occurred audit runner context body) = do
  require (sequenceNumber > 0 && BS.length (encodeEvent event) <= 65536 && not (Text.null runner) && Text.length runner <= 128)
  uuid eventId
  uuid run
  mapM_ uuid attempt
  _ <- auditContext (actor audit) (reason audit) (references audit)
  require (isJust (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (Text.unpack occurred) :: Maybe UTCTime))
  mapM_
    ( \(EventContext component migration checksum step) -> do
        void (either (const (Left InvalidEvent)) Right (Def.componentName component))
        void (either (const (Left InvalidEvent)) Right (Def.migrationName migration))
        checkHash checksum
        mapM_ (\(name, digest) -> void (either (const (Left InvalidEvent)) Right (Def.stepName name)) >> checkHash digest) step
    )
    context
  case body of
    Initialize _ -> require (isNothing attempt && sequenceNumber == 1 && isNothing context)
    StartMigration definition -> needAttempt >> checkDefinition definition >> (contextFor definition Nothing >>= require . (== context) . Just)
    StartStep step query -> needAttempt >> checkStep step query
    SucceedStep step query -> needAttempt >> checkStep step query
    FailStep step query (FailureEvidence code status server) -> needAttempt >> checkStep step query >> require (code `elem` ["ServerRejected", "UnexpectedResponse", "RedirectRejected"] && maybe True (\n -> n >= 100 && n <= 599) status && maybe True (>= 0) server)
    CompleteMigration -> needAttempt
    AuthorizeRecovery (Recovery action (LedgerPosition expected _ previousEvent) previous next (QuiescenceEvidence _ evidenceAudit)) -> do
      needAttempt
      uuid previous
      uuid next
      uuid previousEvent
      require (ledger == expected && previous /= next && all (>= 0) (recoveryStep action) && not (null (references evidenceAudit)))
      _ <- auditContext (actor evidenceAudit) (reason evidenceAudit) (references evidenceAudit)
      pure ()
    AcceptCompletion step evidence -> needAttempt >> require (step >= 0) >> checkEvidence evidence
    StartAdoption (AdoptionBatch source snapshot mapping definition count) -> do
      require (isNothing attempt && isNothing context && not (Text.null (Text.strip source)) && Text.length source <= 2048 && count > 0)
      mapM_ checkHash [snapshot, mapping, definition]
    AdoptEntry definition evidence -> require (isNothing attempt) >> checkDefinition definition >> checkEvidence evidence >> (contextFor definition Nothing >>= require . (== context) . Just)
    CompleteAdoption digest -> require (isNothing attempt && isNothing context) >> checkHash digest
  where
    require True = Right (); require False = Left InvalidEvent
    uuid = either (const (Left InvalidEvent)) (const (Right ())) . Target.ledgerId
    needAttempt = require (isJust attempt && isJust context)
    checkStep step query = require (step >= 0) >> either (const (Left InvalidEvent)) (const (Right ())) (Target.queryId query)
    checkHash digest = require (Text.length digest == 64 && Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) digest)
    checkEvidence (Evidence _ refs) = do
      require (not (null refs))
      void (auditContext "evidence" "evidence" refs)
    checkDefinition (Definition ordinal index component dependencies migration checksum steps) = do
      require (ordinal >= 0 && index >= 0 && not (null steps) && dependencies == Set.toAscList (Set.fromList dependencies) && component `notElem` dependencies)
      void (either (const (Left InvalidEvent)) Right (Def.componentName component))
      void (either (const (Left InvalidEvent)) Right (Def.migrationName migration))
      mapM_ (\dependency -> void (either (const (Left InvalidEvent)) Right (Def.componentName dependency))) dependencies
      checkHash checksum
      require (length steps == Set.size (Set.fromList [name | StepDefinition name _ <- steps]))
      mapM_ (\(StepDefinition name digest) -> void (either (const (Left InvalidEvent)) Right (Def.stepName name)) >> checkHash digest) steps
    actor (AuditContext value _ _) = value
    reason (AuditContext _ value _) = value
    references (AuditContext _ _ value) = value
