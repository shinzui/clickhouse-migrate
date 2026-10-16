-- | Explicit bounded source-neutral input. SQL definitions always come from the
-- compiled plan; historical bytes here can only verify predecessor evidence.
module ClickHouseMigrate.CLI.AdoptionFile (readAdoptionInput, decodeAdoptionInput) where

import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.CLI.Types
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (TargetKey)
import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as Text
import System.IO (IOMode (ReadMode), withBinaryFile)

readAdoptionInput :: FilePath -> IO (Either CommandError ByteString)
readAdoptionInput file = do
  result <- try @IOException (withBinaryFile file ReadMode (\handle -> BS.hGet handle 16777217))
  pure $ case result of Left _ -> Left InputUnavailable; Right bytes | BS.length bytes > 16777216 -> Left InputTooLarge; Right bytes -> Right bytes

-- The public Aeson token API is walked before duplicate keys are discarded,
-- including escaped aliases. Parser errors never carry arbitrary input text.
checkTokens :: Int -> Tokens k String -> Either CommandError k
checkTokens _ (TkLit _ next) = Right next
checkTokens _ (TkText _ next) = Right next
checkTokens _ (TkNumber _ next) = Right next
checkTokens depth (TkArrayOpen values) | depth < 64 = checkArray (depth + 1) values
checkTokens depth (TkRecordOpen pairs) | depth < 64 = checkRecord (depth + 1) Set.empty pairs
checkTokens _ _ = Left InvalidJsonInput

checkArray :: Int -> TkArray k String -> Either CommandError k
checkArray _ (TkArrayEnd next) = Right next
checkArray _ (TkArrayErr _) = Left InvalidJsonInput
checkArray depth (TkItem value) = checkTokens depth value >>= checkArray depth

checkRecord :: Int -> Set Key.Key -> TkRecord k String -> Either CommandError k
checkRecord _ _ (TkRecordEnd next) = Right next
checkRecord _ _ (TkRecordErr _) = Left InvalidJsonInput
checkRecord depth seen (TkPair key value)
  | Set.member key seen = Left DuplicateJsonKey
  | otherwise = checkTokens depth value >>= checkRecord depth (Set.insert key seen)

objectAt :: [Key.Key] -> Value -> Either CommandError (KM.KeyMap Value)
objectAt allowed (Object value) | all (`elem` allowed) (KM.keys value) = Right value
objectAt _ _ = Left InvalidAdoptionInput

member :: Key.Key -> KM.KeyMap Value -> Either CommandError Value
member name = maybe (Left InvalidAdoptionInput) Right . KM.lookup name

textAt :: Value -> Either CommandError Text
textAt (String value) = Right value
textAt _ = Left InvalidAdoptionInput

arrayAt :: Value -> Either CommandError [Value]
arrayAt (Array values) | length values <= 1000 = Right (toList values)
arrayAt (Array _) = Left InputTooLarge
arrayAt _ = Left InvalidAdoptionInput

unhex :: Text -> Either CommandError ByteString
unhex value
  | Text.length value > 4194304 = Left InputTooLarge
  | odd (Text.length value) = Left InvalidAdoptionInput
  | otherwise = BS.pack <$> go [] (Text.unpack value)
  where
    nibble c
      | c >= '0' && c <= '9' = Right (fromEnum c - fromEnum '0')
      | c >= 'a' && c <= 'f' = Right (fromEnum c - fromEnum 'a' + 10)
      | otherwise = Left InvalidAdoptionInput
    go acc [] = Right (reverse acc)
    go acc (a : b : rest) = do x <- nibble a; y <- nibble b; go (fromIntegral (x * 16 + y) : acc) rest
    go _ _ = Left InvalidAdoptionInput

core :: Either A.AdoptionError a -> Either CommandError a
core = either (const (Left InvalidAdoptionInput)) Right

decodeAdoptionInput :: TargetKey -> L.ExpectedLedgerState -> Maybe L.InitializationAuthorization -> L.QuiescenceEvidence -> L.AuditContext -> ByteString -> Either CommandError A.AdoptionRequest
decodeAdoptionInput target expected authorization quiet audit bytes = do
  when (BS.length bytes > 16777216) (Left InputTooLarge)
  _ <- checkTokens 0 (bsToTokens bytes)
  value <- either (const (Left InvalidJsonInput)) Right (eitherDecodeStrict' bytes)
  object <- objectAt ["schemaVersion", "source", "snapshotReference", "rows", "mappings"] value
  version <- member "schemaVersion" object
  unless (version == Number 1) (Left UnsupportedInputVersion)
  source <- member "source" object >>= textAt
  reference <- member "snapshotReference" object >>= textAt
  rows <- member "rows" object >>= arrayAt >>= traverse parseRow
  mappings <- member "mappings" object >>= arrayAt >>= traverse parseMapping
  nonemptyRows <- maybe (Left InvalidAdoptionInput) Right (NE.nonEmpty rows)
  nonemptyMappings <- maybe (Left InvalidAdoptionInput) Right (NE.nonEmpty mappings)
  core (A.adoptionRequest target expected authorization quiet audit source reference nonemptyRows nonemptyMappings)
  where
    parseRow value = do
      object <- objectAt ["id", "appliedAt", "checksum"] value
      identity <- member "id" object >>= textAt
      appliedAt <- member "appliedAt" object >>= textAt
      checksum <- case KM.lookup "checksum" object of
        Nothing -> Right Nothing
        Just Null -> Right Nothing
        Just stored -> do
          fields <- objectAt ["algorithm", "digest"] stored
          algorithm <- member "algorithm" fields >>= textAt
          digest <- member "digest" fields >>= textAt
          Just <$> core (A.sourceChecksum algorithm digest)
      core (A.legacyRow identity appliedAt checksum)
    parseMapping value = do
      object <- objectAt ["row", "component", "migration", "checksum", "evidence"] value
      row <- member "row" object >>= textAt
      component <- member "component" object >>= textAt
      migration <- member "migration" object >>= textAt
      checksum <- member "checksum" object >>= textAt
      evidence <- member "evidence" object >>= objectAt ["level", "references", "historicalBytesHex"]
      level <- member "level" evidence >>= textAt
      refs <- member "references" evidence >>= arrayAt >>= traverse textAt
      case level of
        "operator-attestation" | not (KM.member "historicalBytesHex" evidence) -> core (A.attestedMapping row component migration checksum refs)
        "predecessor-checksum" -> do historical <- member "historicalBytesHex" evidence >>= textAt >>= unhex; core (A.verifiedMapping row component migration checksum historical refs)
        _ -> Left InvalidAdoptionInput
