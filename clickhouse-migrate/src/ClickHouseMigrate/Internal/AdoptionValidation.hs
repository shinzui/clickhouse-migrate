-- | Versioned whole-batch validation. No IO, SQL splitting or schema inference.
module ClickHouseMigrate.Internal.AdoptionValidation where

import ClickHouseMigrate.Definition qualified as Def
import ClickHouseMigrate.Internal.AdoptionTypes
import ClickHouseMigrate.Internal.Checksum qualified as Hash
import ClickHouseMigrate.Internal.LedgerCodec qualified as Codec
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Reporting qualified as Reporting
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target (TargetKey, ledgerId)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (Builder, byteString, toLazyByteString, word64BE)
import Data.ByteString.Lazy qualified as Lazy
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

require :: AdoptionError -> Bool -> Either AdoptionError ()
require failure condition = if condition then Right () else Left failure

validText :: Int -> Text -> Bool
validText bound value = not (Text.null (Text.strip value)) && Text.length value <= bound && not (Text.any (`elem` ['\0', '\n', '\r']) value)

validHash :: Text -> Bool
validHash value = Text.length value == 64 && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value

references :: [Text] -> Either AdoptionError ()
references refs = do
  require InvalidSourceEvidence (not (null refs) && length refs <= 24)
  either (const (Left InvalidSourceEvidence)) (const (Right ())) (Ledger.auditContext "adoption evidence" "reviewed mapping" refs)

sourceChecksum :: Text -> Text -> Either AdoptionError SourceChecksum
sourceChecksum algorithm digest = do
  require UnsupportedSourceChecksum (algorithm == "sha256")
  require InvalidSourceChecksum (validHash digest)
  pure (SourceChecksum algorithm digest)

legacyRow :: Text -> Text -> Maybe SourceChecksum -> Either AdoptionError LegacyRow
legacyRow identity appliedAt checksum = do
  require InvalidSourceEvidence (validText 512 identity && validText 256 appliedAt)
  pure (LegacyRow identity appliedAt checksum)

mapping :: Text -> Text -> Text -> Text -> MappingEvidence -> Either AdoptionError AdoptionMapping
mapping row component migration checksum evidence = do
  require InvalidSourceEvidence (validText 512 row && validHash checksum)
  either (const (Left MappingDefinitionMismatch)) (const (Right ())) (Def.componentName component)
  either (const (Left MappingDefinitionMismatch)) (const (Right ())) (Def.migrationName migration)
  case evidence of
    Attested refs -> references refs
    Verified bytes refs -> require AdoptionBatchTooLarge (BS.length bytes <= 2097152) >> references refs
  pure (AdoptionMapping row component migration checksum evidence)

adoptionRequest :: TargetKey -> L.ExpectedLedgerState -> Maybe L.InitializationAuthorization -> L.QuiescenceEvidence -> L.AuditContext -> Text -> Text -> NE.NonEmpty LegacyRow -> NE.NonEmpty AdoptionMapping -> Either AdoptionError AdoptionRequest
adoptionRequest target expected authorization quiet audit source reference rows mappings = do
  require InvalidSourceEvidence (validText 512 source && validText 1000 reference && not (null (Ledger.auditReferences audit)))
  require AdoptionBatchTooLarge (NE.length rows <= 1000 && NE.length mappings <= 1000)
  let historicalBytes = sum [BS.length bytes | AdoptionMapping _ _ _ _ (Verified bytes _) <- NE.toList mappings]
      referenceBytes = sum [sum (map (BS.length . Encoding.encodeUtf8) refs) | AdoptionMapping _ _ _ _ evidence <- NE.toList mappings, refs <- [case evidence of Attested values -> values; Verified _ values -> values]]
  require AdoptionBatchTooLarge (historicalBytes <= 67108864 && referenceBytes <= 8388608)
  require AdoptionTargetMismatch (Ledger.quiescenceTarget quiet == target)
  case expected of
    L.ExpectAbsent actual -> require AdoptionTargetMismatch (actual == target) >> require AdoptionInitializationRequired (isJust authorization)
    L.ExpectPosition (L.LedgerPosition expectedLedger _ _) -> case authorization of
      Just (L.InitializationAuthorization _ authorizedLedger _) -> require AdoptionTargetMismatch (expectedLedger == authorizedLedger)
      _ -> pure ()
  case authorization of Just (L.InitializationAuthorization actual _ _) -> require AdoptionTargetMismatch (actual == target); _ -> pure ()
  pure (AdoptionRequest target expected authorization quiet audit source reference (NE.toList rows) (NE.toList mappings))

field :: ByteString -> Builder
field bytes = word64BE (fromIntegral (BS.length bytes)) <> byteString bytes

textField :: Text -> Builder
textField = field . Encoding.encodeUtf8

list :: (a -> Builder) -> [a] -> Builder
list encode values = word64BE (fromIntegral (length values)) <> foldMap encode values

hashEncoding :: ByteString -> Builder -> Text
hashEncoding domain value = Hash.digestHex (Hash.digest (Lazy.toStrict (toLazyByteString (byteString domain <> value))))

snapshotDigest :: Text -> Text -> [LegacyRow] -> Text
snapshotDigest source reference rows = hashEncoding "clickhouse-migrate/adoption-snapshot\0v1\0" (textField source <> textField reference <> list encode rows)
  where
    encode (LegacyRow identity appliedAt checksum) = textField identity <> textField appliedAt <> case checksum of Nothing -> word64BE 0; Just (SourceChecksum algorithm digest) -> word64BE 1 <> textField algorithm <> textField digest

mappingDigest :: Text -> [(Text, L.Definition, L.Evidence)] -> Text
mappingDigest snapshot entries = hashEncoding "clickhouse-migrate/adoption-mapping\0v1\0" (textField snapshot <> list encode entries)
  where
    encode (row, definition, L.Evidence level refs) = textField row <> field (Codec.encodeValue (Codec.definitionValue definition)) <> word64BE (case level of L.OperatorAttestation -> 0; L.PredecessorChecksum -> 1) <> list textField refs

buildBatch :: Plan.MigrationPlan -> AdoptionRequest -> Either AdoptionError (L.AdoptionBatch, [(L.Definition, L.Evidence)])
buildBatch plan (AdoptionRequest _ _ _ _ audit source reference rows mappings) = do
  let rowIds = [identity | LegacyRow identity _ _ <- rows]
      mappingIds = [identity | AdoptionMapping identity _ _ _ _ <- mappings]
      nativeIds = [(component, migration) | AdoptionMapping _ component migration _ _ <- mappings]
      supplied = Codec.definitions plan
  require DuplicateSourceRow (Set.size (Set.fromList rowIds) == length rowIds)
  require DuplicateMapping (Set.size (Set.fromList mappingIds) == length mappingIds && Set.size (Set.fromList nativeIds) == length nativeIds)
  require UnknownSourceRow (all (`elem` rowIds) mappingIds)
  require IncompleteMapping (Set.fromList rowIds == Set.fromList mappingIds && length mappings <= length supplied)
  require MappingOrderMismatch (rowIds == mappingIds)
  identity <- either (const (Left InvalidSourceEvidence)) Right (ledgerId "00000000-0000-4000-8000-000000000000")
  entries <- sequence [entry row mapped definition | (row, mapped, definition) <- zip3 rows mappings supplied]
  let snapshot = snapshotDigest source reference rows
      mapped = mappingDigest snapshot entries
      definitions = [(definition, evidence) | (_, definition, evidence) <- entries]
      batch = L.AdoptionBatch (source <> "\nsnapshot-evidence:" <> reference) snapshot mapped (Codec.definitionsDigest (map fst definitions)) (length definitions)
      uuid = "00000000-0000-4000-8000-000000000000"
      event body context = L.LedgerEvent 1 uuid identity uuid Nothing "2026-10-16T00:00:00.999999999999Z" audit "0.1.0.0" context body
  -- Validate each full serialized entry before initialization. Descriptors may
  -- approach the wire bound even when individual user fields are valid.
  mapM_
    ( \(definition, evidence) -> do
        context <- either (const (Left MappingDefinitionMismatch)) Right (Codec.contextFor definition Nothing)
        let encoded = event (L.AdoptEntry definition evidence) (Just context)
        either (const (Left InvalidSourceEvidence)) pure (Codec.validateEvent encoded)
        require AdoptionBatchTooLarge (BS.length (Codec.encodeEvent encoded) <= 61440)
    )
    definitions
  mapM_
    ( \body -> do
        let encoded = event body Nothing
        either (const (Left InvalidSourceEvidence)) pure (Codec.validateEvent encoded)
        require AdoptionBatchTooLarge (BS.length (Codec.encodeEvent encoded) <= 61440)
    )
    [L.StartAdoption batch, L.CompleteAdoption mapped]
  pure (batch, definitions)
  where
    entry (LegacyRow row _ checksum) (AdoptionMapping mapped component migration digest evidence) definition = do
      require MappingOrderMismatch (row == mapped)
      require MappingDefinitionMismatch (component == L.component definition && migration == L.migration definition && digest == L.checksum definition)
      let sourceRefs = ["source:" <> source, "snapshot-evidence:" <> reference, "source-row:" <> row]
      accepted <- case evidence of
        Attested refs -> pure (L.Evidence L.OperatorAttestation (sourceRefs ++ refs))
        Verified bytes refs -> case checksum of
          Nothing -> Left HistoricalChecksumRequired
          Just (SourceChecksum algorithm historical) -> do
            require HistoricalChecksumMismatch (algorithm == "sha256" && Hash.digestHex (Hash.digest bytes) == historical)
            pure (L.Evidence L.PredecessorChecksum (sourceRefs ++ ["historical-algorithm:" <> algorithm, "historical-checksum:" <> historical] ++ refs))
      pure (row, definition, accepted)

-- An identical committed batch is inspection-only, including after later native
-- execution. Every mutating path must match its fresh expected observation.
checkHistory :: AdoptionRequest -> L.AdoptionBatch -> [(L.Definition, L.Evidence)] -> R.HistoryReport -> Either AdoptionError Bool
checkHistory (AdoptionRequest target expected authorization _ _ _ _ _ _) batch entries (R.HistoryReport observed _ presence position _ events migrations unresolved) = do
  require AdoptionTargetMismatch (target == observed)
  case (expected, position) of
    (L.ExpectPosition (L.LedgerPosition wanted _ _), Just (L.LedgerPosition actual _ _)) -> require AdoptionTargetMismatch (wanted == actual)
    _ -> pure ()
  case (authorization, position) of
    (Just (L.InitializationAuthorization _ wanted _), Just (L.LedgerPosition actual _ _)) -> require AdoptionTargetMismatch (wanted == actual)
    _ -> pure ()
  let batches = [fromSummary summary | R.HistoryEvent _ _ _ _ _ _ _ _ _ (R.AdoptionBeginning summary) <- events]
      committed = [completion | R.HistoryEvent _ _ _ _ _ _ _ _ _ (R.AdoptionCompletion completion) <- events]
      actual = [(definition, level, refs) | R.HistoryEvent _ _ _ _ _ _ _ _ _ (R.AdoptedDefinition definition (R.EvidenceSummary level refs)) <- events]
      wanted = [(Reporting.summaryDefinition definition, level, refs) | (definition, L.Evidence level refs) <- entries]
      L.AdoptionBatch _ _ digest _ _ = batch
  if batches == [batch] && committed == [digest]
    then require AdoptionBatchConflict (actual == wanted) >> Right True
    else do
      require AdoptionExpectedStateMismatch (case expected of L.ExpectAbsent _ -> presence `elem` [R.LedgerMissing, R.LedgerUninitialized] && isNothing position; L.ExpectPosition value -> position == Just value)
      require AdoptionNativeConflict (null [() | R.HistoryEvent _ _ _ _ _ _ _ _ _ (R.MigrationDefinition _) <- events])
      case batches of
        [] -> require AdoptionNativeConflict (null migrations && not unresolved)
        [existing] -> require AdoptionBatchConflict (existing == batch && null committed && actual == take (length actual) wanted)
        _ -> Left AdoptionBatchConflict
      pure False
  where
    fromSummary (R.AdoptionSummary source snapshot mapped definitions count) = L.AdoptionBatch source snapshot mapped definitions count
