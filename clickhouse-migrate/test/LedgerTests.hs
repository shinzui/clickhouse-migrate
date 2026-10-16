module LedgerTests (ledgerTests) where

import ClickHouseMigrate
import ClickHouseMigrate.Internal.LedgerCodec qualified as Codec
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Preflight (validateRecoveryCapacity, validateRecoveryEvent)
import ClickHouseMigrate.Internal.Projection qualified as Projection
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Report qualified as R
import Control.Monad (forM_, unless)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word64)

assert :: String -> Bool -> IO ()
assert label predicate = unless predicate (fail ("ledger: " ++ label))

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

ledgerTests :: IO ()
ledgerTests = do
  target <- right (targetKey "development/main")
  ledger <- right (ledgerId (uuid 99))
  audit <- right (Ledger.auditContext "operator's \"review\"" "test\nreason" ["mori://shinzui/clickhouse-migrate"])
  quiescence <- right (Ledger.attestQuiescence target audit)
  s1 <- right (sqlStep "first" "CREATE TABLE app.a (x UInt8)")
  s2 <- right (sqlStep "second" "ALTER TABLE app.a ADD COLUMN y UInt8")
  m <- right (sqlMigration "m" (s1 :| [s2]))
  c <- right (migrationComponent "app" Set.empty (m :| []))
  plan <- right (migrationPlan (c :| []))
  definition <- case Codec.definitions plan of [value] -> pure value; _ -> fail "Expected one test definition"
  recoveryEnvelopeTests target ledger definition
  let attempt = uuid 100
      event n a body = L.LedgerEvent n (uuid n) ledger (uuid 98) a "2026-10-16T00:00:00Z" audit "0.1.0.0" (eventContext body) body
      eventContext body = case body of
        L.Initialize _ -> Nothing
        L.StartAdoption _ -> Nothing
        L.CompleteAdoption _ -> Nothing
        _ ->
          either
            (error "Invalid test context")
            Just
            ( Codec.contextFor
                definition
                ( case body of
                    L.StartStep i _ -> Just i
                    L.SucceedStep i _ -> Just i
                    L.FailStep i _ _ -> Just i
                    L.AcceptCompletion i _ -> Just i
                    L.AuthorizeRecovery (L.Recovery action _ _ _ _) -> case action of L.RetryStep i -> Just i; L.AcceptStep i -> Just i; _ -> Nothing
                    _ -> Nothing
                )
            )
      initialized = event 1 Nothing (L.Initialize target)
      start = event 2 (Just attempt) (L.StartMigration definition)
      first = event 3 (Just attempt) (L.StartStep 0 "first-query")
      success = event 4 (Just attempt) (L.SucceedStep 0 "first-query")
      second = event 5 (Just attempt) (L.StartStep 1 "second-query")
      succeeded = event 6 (Just attempt) (L.SucceedStep 1 "second-query")
      complete = event 7 (Just attempt) L.CompleteMigration
      good = [initialized, start, first, success, second, succeeded, complete]
      fold = Projection.project target
      position n = L.LedgerPosition ledger n (uuid n)
      rejection label code result = assert label (either (== code) (const False) result)
  forM_ good $ \value -> assert "wire roundtrip" (Codec.decodeEvent (Codec.encodeEvent value) == Right value)
  golden <- BS.readFile "test/vectors/ledger-initialized-v1.json"
  assert "frozen independent JSON spelling" (Codec.encodeEvent initialized == BS.takeWhile (/= 10) golden)
  forM_ ["{}", Codec.encodeEvent initialized <> " ", "{\"version\":1,\"version\":1}", BS.take (BS.length (Codec.encodeEvent initialized) - 1) (Codec.encodeEvent initialized)] $ \bad ->
    assert "reject incomplete/noncanonical/duplicate fields" (either (const True) (const False) (Codec.decodeEvent bad))
  projection <- right (fold good)
  assert "applied and compatible" (not (Projection.unresolved projection) && Projection.comparePlan plan projection == Right ())
  assert "collapse only identical duplicates independent of storage order" (fold (reverse good ++ good) == Right projection)
  rejection "sequence conflict" L.SequenceConflict (fold (good ++ [first {L.eventId = uuid 77}]))
  rejection "identity conflict" L.EventIdentityConflict (fold (good ++ [first {L.sequence = 8}]))
  rejection "sequence gap" L.SequenceGap (fold [initialized, start, success])
  rejection "missing initialization" L.MissingInitialization (fold [start])
  rejection "unknown UUID binding" L.LedgerIdentityMismatch (fold [initialized, start {L.ledgerId = either (error "test UUID") id (ledgerId (uuid 88))}])
  rejection "success without intent" L.ImpossibleTransition (fold [initialized, start, success {L.sequence = 3, L.eventId = uuid 3}])
  rejection "out-of-order step" L.ImpossibleTransition (fold [initialized, start, first {L.body = L.StartStep 1 "second-query", L.context = eventContext (L.StartStep 1 "second-query")}])
  rejection "premature completion" L.ImpossibleTransition (fold [initialized, start, first {L.body = L.CompleteMigration, L.context = eventContext L.CompleteMigration}])
  forM_ [take 2 good, take 3 good, take 4 good, take 6 good] $ \prefix -> do
    state <- right (fold prefix)
    assert "every interrupted attempt blocks regardless of checkpoint" (Projection.unresolved state)
  changed <- right (migrationComponent "before" Set.empty (m :| []))
  inserted <- right (migrationPlan (changed :| [c]))
  rejection "component insertion shifts global prefix" L.DefinitionMismatch (Projection.comparePlan inserted projection)
  dep <- right (migrationComponent "app" (Set.singleton "before") (m :| []))
  changedDeps <- right (migrationPlan (changed :| [dep]))
  rejection "dependency/order mismatch" L.DefinitionMismatch (Projection.comparePlan changedDeps projection)
  let failed = event 4 (Just attempt) (L.FailStep 0 "first-query" (L.FailureEvidence "ServerRejected" (Just 500) (Just 60)))
  state <- right (fold [initialized, start, first, failed])
  assert "observed server failure unresolved" (Projection.unresolved state)
  let next = uuid 101
      authorize n previousPos action = event n (Just next) (L.AuthorizeRecovery (L.Recovery action previousPos attempt next quiescence))
      authorized = authorize 5 (position 4) (L.AcceptStep 0)
      accepted = event 6 (Just next) (L.AcceptCompletion 0 (L.Evidence L.OperatorAttestation ["operator inspected effects"]))
      resumed = event 7 (Just next) (L.StartStep 1 "after-accept")
      done = event 8 (Just next) (L.SucceedStep 1 "after-accept")
      final = event 9 (Just next) L.CompleteMigration
  recovered <- right (fold [initialized, start, first, failed, authorized, accepted, resumed, done, final])
  assert "accepted completion stays distinct" (case L.completed recovered of [L.RecordedMigration _ L.Applied (L.Accepted _ : _)] -> True; _ -> False)
  rejection "stale recovery position" L.StaleLedgerState (fold [initialized, start, first, failed, authorize 5 (position 3) (L.AcceptStep 0)])
  rejection "retry wrong step" L.ImpossibleTransition (fold [initialized, start, first, failed, authorize 5 (position 4) (L.RetryStep 1)])
  rejection "resume uncertain work" L.ImpossibleTransition (fold [initialized, start, first, failed, authorize 5 (position 4) L.Resume])
  retry <- right (fold [initialized, start, first, failed, authorize 5 (position 4) (L.RetryStep 0), event 6 (Just next) (L.StartStep 0 "new-query")])
  assert "retry uses a fresh query" (Projection.unresolved retry)
  rejection "query ID reuse" L.ImpossibleTransition (fold [initialized, start, first, failed, authorize 5 (position 4) (L.RetryStep 0), event 6 (Just next) (L.StartStep 0 "first-query")])
  let hash = Text.replicate 64 "a"
      batch = L.AdoptionBatch "legacy" hash hash (Codec.definitionsDigest [definition]) 1
      begin = event 2 Nothing (L.StartAdoption batch)
      entry = event 3 Nothing (L.AdoptEntry definition (L.Evidence L.OperatorAttestation ["historical filename only"]))
      end = event 4 Nothing (L.CompleteAdoption hash)
  partial <- right (fold [initialized, begin, entry])
  assert "incomplete adoption blocks" (Projection.unresolved partial)
  adopted <- right (fold [initialized, begin, entry, end])
  assert "complete adoption compatible" (not (Projection.unresolved adopted) && Projection.comparePlan plan adopted == Right ())
  rejection "incomplete batch cannot complete" L.ImpossibleTransition (fold [initialized, begin, end {L.sequence = 3, L.eventId = uuid 3}])
  rejection "adoption definition digest mismatch" L.ImpossibleTransition (fold [initialized, begin {L.body = L.StartAdoption (L.AdoptionBatch "legacy" hash hash hash 1)}, entry, end])
  request <- right (queryId "ledger-insert-query")
  let receipt = L.AppendReceipt target ledger 7 (uuid 7) (Text.replicate 64 "a") request
  assert "append receipt CLI roundtrip" (Ledger.parseAppendReceipt (Ledger.appendReceiptText receipt) == Right receipt && Ledger.appendQueryId receipt == request)
  forM_ [("\"version\":1", "\"version\":2"), ("\"kind\":\"initialized\"", "\"kind\":\"future-kind\"")] $ \(before, after) ->
    assert "unknown event version/kind blocks" (either (const True) (const False) (Codec.decodeEvent (Encoding.encodeUtf8 (Text.replace before after (Encoding.decodeUtf8 (Codec.encodeEvent initialized))))))
  assert "position CLI roundtrip" (Ledger.parseLedgerPosition (Ledger.ledgerPositionText (position 7)) == Right (position 7))
  assert "position text is canonical" (Ledger.parseLedgerPosition ("chm1:" <> ledgerIdText ledger <> ":007:" <> uuid 7) == Left L.InvalidPosition)
  assert "quiescence needs evidence" (either (== L.InvalidEvidence) (const False) (Ledger.auditContext "actor" "reason" [] >>= Ledger.attestQuiescence target))
  putStrLn "Ledger wire, corruption, global prefix, interrupted execution, recovery and adoption projection checks passed."

uuid :: Word64 -> Text
uuid n = "00000000-0000-4000-8000-" <> Text.justifyRight 12 '0' (Text.pack (show n))

recoveryEnvelopeTests :: TargetKey -> LedgerId -> L.Definition -> IO ()
recoveryEnvelopeTests target ledger definition = do
  assert "deterministic recovery capacity" (validateRecoveryCapacity (maxBound - 2) 2 == Right ())
  assert "capacity rejected before authorization" (validateRecoveryCapacity (maxBound - 1) 2 == Left (R.LedgerFailed L.LedgerLimitExceeded))
  let makeAudit actor reason count = right (Ledger.auditContext actor reason (replicate 15 (Text.replicate 2048 "x") ++ [Text.replicate count "x"]))
      context = either (error . show) id (Codec.contextFor definition (Just 0))
      envelope audit body = L.LedgerEvent 5 (uuid 5) ledger (uuid 90) (Just (uuid 91)) "2026-10-16T00:00:00.123456789012Z" audit "0.1.0.0" (Just context) body
      acceptance audit = envelope audit (L.AcceptCompletion 0 (L.Evidence L.OperatorAttestation (Ledger.auditReferences audit)))
  base <- makeAudit "op" "r" 1
  let remaining = Codec.maxEventBytes - BS.length (Codec.encodeEvent (acceptance base))
      actor = if odd remaining then "ops" else "op"
      count = 1 + remaining `div` 2
  exactAudit <- makeAudit actor "r" count
  tooLargeAudit <- makeAudit actor "rr" count
  let exact = acceptance exactAudit
      over = acceptance tooLargeAudit
  assert "exact canonical recovery byte bound" (BS.length (Codec.encodeEvent exact) == Codec.maxEventBytes && validateRecoveryEvent R.RecoveryAcceptanceEvent exact == Right ())
  assert "bound plus one typed error" (BS.length (Codec.encodeEvent over) == Codec.maxEventBytes + 1 && validateRecoveryEvent R.RecoveryAcceptanceEvent over == Left (R.RecoveryEventTooLarge R.RecoveryAcceptanceEvent))
  assert "canonical size roundtrip" (Codec.decodeEvent (Codec.encodeEvent exact) == Right exact)
  -- Even a worst possible JSON escape expansion of every event byte fits the
  -- default row limit. Valid canonical event bytes are a subset of this bound.
  let worstRow = Codec.encodeValue (object ["sequence" .= ("18446744073709551615" :: Text), "event_id" .= uuid 5, "ledger_id" .= uuid 99, "event" .= Text.replicate Codec.maxEventBytes "\SOH"])
  assert "default accommodates worst escaped row" (BS.length worstRow < 1048576)
  forM_ ["雪", "\"", "\\", "x\n"] $ \unit -> do
    audit <- right (Ledger.auditContext "op" "r" (replicate 16 (Text.replicate 1024 unit)))
    assert "UTF-8/JSON escaping counted" (validateRecoveryEvent R.RecoveryAcceptanceEvent (acceptance audit) == Left (R.RecoveryEventTooLarge R.RecoveryAcceptanceEvent))
  outer <- right (Ledger.auditContext "op" "r" (replicate 16 (Text.replicate 2048 "x")))
  quiet <- right (Ledger.attestQuiescence target outer)
  let authorization = envelope outer (L.AuthorizeRecovery (L.Recovery (L.AcceptStep 0) (L.LedgerPosition ledger 4 (uuid 4)) (uuid 92) (uuid 91) quiet))
  assert "combined independently valid audits" (validateRecoveryEvent R.RecoveryAuthorizationEvent authorization == Left (R.RecoveryEventTooLarge R.RecoveryAuthorizationEvent))
