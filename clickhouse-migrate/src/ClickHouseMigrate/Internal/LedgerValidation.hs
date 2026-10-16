-- | Validated ledger observations and explicit administrative assertions.
-- Assertions document caller evidence; they do not independently prove fencing.
module ClickHouseMigrate.Internal.LedgerValidation
  ( AttemptId,
    parseAttemptId,
    attemptIdText,
    LedgerPosition,
    ledgerPositionText,
    parseLedgerPosition,
    AppendReceipt,
    appendReceiptText,
    parseAppendReceipt,
    appendQueryId,
    ExpectedLedgerState (ExpectAbsent, ExpectPosition),
    AuditContext,
    auditContext,
    auditActor,
    auditReason,
    auditReferences,
    QuiescenceEvidence,
    attestQuiescence,
    quiescenceTarget,
    InitializationAuthorization,
    authorizeInitialization,
    EvidenceLevel (OperatorAttestation, PredecessorChecksum),
    LedgerError (..),
  )
where

import ClickHouseMigrate.Internal.LedgerTypes
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target qualified as Target
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word64)
import Numeric (readHex, showHex)
import Text.Read (readMaybe)

ledgerPositionText :: LedgerPosition -> Text
ledgerPositionText (LedgerPosition identity sequenceNumber event) =
  "chm1:" <> Target.ledgerIdText identity <> ":" <> Text.pack (show sequenceNumber) <> ":" <> event

parseLedgerPosition :: Text -> Either LedgerError LedgerPosition
parseLedgerPosition encoded = case Text.splitOn ":" encoded of
  ["chm1", uuid, number, event] -> do
    identity <- either (const (Left InvalidPosition)) Right (Target.ledgerId uuid)
    _ <- either (const (Left InvalidPosition)) Right (Target.ledgerId event)
    sequenceNumber <- maybe (Left InvalidPosition) Right (readMaybe (Text.unpack number) :: Maybe Word64)
    let result = LedgerPosition identity sequenceNumber event
    if sequenceNumber > 0 && ledgerPositionText result == encoded then Right result else Left InvalidPosition
  _ -> Left InvalidPosition

auditContext :: Text -> Text -> [Text] -> Either LedgerError AuditContext
auditContext actor reason references
  | bounded 256 actor && bounded 4096 reason && length references <= 32 && all (bounded 2048) references = Right (AuditContext actor reason references)
  | otherwise = Left InvalidAudit
  where
    bounded limit value = not (Text.null (Text.strip value)) && Text.length value <= limit && not (Text.any (== '\0') value)

auditActor :: AuditContext -> Text
auditActor (AuditContext value _ _) = value

auditReason :: AuditContext -> Text
auditReason (AuditContext _ value _) = value

auditReferences :: AuditContext -> [Text]
auditReferences (AuditContext _ _ value) = value

-- | Caller attests that every predecessor has been fenced and ALL of its server
-- requests (including initialization DDL/ledger INSERTs) have ended. An empty
-- read, released OS lock, expired lease or absent process ID is insufficient.
attestQuiescence :: Target.TargetKey -> AuditContext -> Either LedgerError QuiescenceEvidence
attestQuiescence target audit@(AuditContext _ _ references)
  | null references = Left InvalidEvidence
  | otherwise = Right (QuiescenceEvidence target audit)

-- | A one-time target/UUID-bound first-use authorization. Persist this UUID with
-- an interrupted bootstrap; never generate a different one to resume it.
authorizeInitialization :: Target.TargetKey -> Target.LedgerId -> AuditContext -> InitializationAuthorization
authorizeInitialization = InitializationAuthorization

appendReceiptText :: AppendReceipt -> Text
appendReceiptText (AppendReceipt target ledger sequenceNumber event digest query) =
  Text.intercalate ":" ["chm-receipt1", hex (Encoding.encodeUtf8 (Target.targetKeyText target)), Target.ledgerIdText ledger, Text.pack (show sequenceNumber), event, digest, Target.queryIdText query]
  where
    hex = Text.pack . concatMap (\byte -> let value = showHex byte "" in replicate (2 - length value) '0' ++ value) . BS.unpack

parseAppendReceipt :: Text -> Either LedgerError AppendReceipt
parseAppendReceipt encoded = case Text.splitOn ":" encoded of
  ["chm-receipt1", targetHex, ledger, number, event, digest, query] | Text.length encoded <= 1024 -> do
    bytes <- unhex (Text.unpack targetHex)
    targetText <- either (const (Left InvalidPosition)) Right (Encoding.decodeUtf8' (BS.pack bytes))
    target <- either (const (Left InvalidPosition)) Right (Target.targetKey targetText)
    identity <- either (const (Left InvalidPosition)) Right (Target.ledgerId ledger)
    _ <- either (const (Left InvalidPosition)) Right (Target.ledgerId event)
    sequenceNumber <- maybe (Left InvalidPosition) Right (readMaybe (Text.unpack number) :: Maybe Word64)
    request <- either (const (Left InvalidPosition)) Right (Target.queryId query)
    let result = AppendReceipt target identity sequenceNumber event digest request
    if sequenceNumber > 0 && Text.length digest == 64 && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') digest && appendReceiptText result == encoded then Right result else Left InvalidPosition
  _ -> Left InvalidPosition
  where
    unhex [] = Right []
    unhex (a : b : rest) = case readHex [a, b] of [(byte, "")] -> (byte :) <$> unhex rest; _ -> Left InvalidPosition
    unhex _ = Left InvalidPosition

quiescenceTarget :: QuiescenceEvidence -> Target.TargetKey
quiescenceTarget (QuiescenceEvidence target _) = target

appendQueryId :: AppendReceipt -> Target.QueryId
appendQueryId (AppendReceipt _ _ _ _ _ query) = query

parseAttemptId :: Text -> Either LedgerError AttemptId
parseAttemptId value = either (const (Left InvalidPosition)) (const (Right (AttemptId value))) (Target.ledgerId value)

attemptIdText :: AttemptId -> Text
attemptIdText (AttemptId value) = value
