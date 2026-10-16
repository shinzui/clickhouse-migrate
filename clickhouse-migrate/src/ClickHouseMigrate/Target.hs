-- | Explicit, validated configuration for one direct administrative target.
module ClickHouseMigrate.Target
  ( TargetKey,
    targetKey,
    targetKeyText,
    DirectEndpoint,
    directEndpoint,
    endpointText,
    ServerId,
    serverId,
    serverIdText,
    QueryId,
    queryId,
    queryIdText,
    LedgerId,
    ledgerId,
    newLedgerId,
    ledgerIdText,
    LedgerNamespace,
    ledgerNamespace,
    ledgerNamespaceText,
    LedgerBinding (FirstUse, ExistingLedger),
    Credentials,
    basicCredentials,
    HttpLimits,
    httpLimits,
    defaultHttpLimits,
    TargetConfig,
    targetConfig,
    configuredTargetKey,
    configuredLedgerBinding,
    TargetError (..),
    ServerIdentity,
    identityServerId,
    identityVersion,
    identityHostName,
  )
where

import ClickHouseMigrate.Internal.Identity (freshUuid)
import ClickHouseMigrate.Internal.TargetTypes
import ClickHouseMigrate.Prelude
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Text.Read (readMaybe)

data TargetError = InvalidTargetKey | InvalidEndpoint | InvalidServerId | InvalidQueryId | InvalidLedgerId | InvalidLedgerNamespace | InvalidCredentials | InvalidHttpLimits
  deriving stock (Eq, Ord, Show)

targetKey :: Text -> Either TargetError TargetKey
targetKey value
  | valid 256 (\c -> lowerDigit c || c `elem` ("/_:.-" :: String)) value && maybe False (lowerDigit . fst) (Text.uncons value) = Right (TargetKey value)
  | otherwise = Left InvalidTargetKey

directEndpoint :: Text -> Either TargetError DirectEndpoint
directEndpoint value = do
  authority <- case Text.stripPrefix "http://" value of
    Just rest -> Right rest
    Nothing -> maybe (Left InvalidEndpoint) Right (Text.stripPrefix "https://" value)
  let hostPort = maybe authority id (Text.stripSuffix "/" authority)
      validHost c = isAsciiLower c || isAsciiUpper c || digit c || c `elem` (".-" :: String)
      validPort "" = True
      validPort suffix = case Text.stripPrefix ":" suffix of
        Just port | not (Text.null port) && Text.all digit port -> case readMaybe (Text.unpack port) :: Maybe Int of
          Just n -> n > 0 && n <= 65535
          _ -> False
        _ -> False
      validAuthority = case Text.stripPrefix "[" hostPort of
        Just ipv6 -> case Text.breakOn "]" ipv6 of
          (host, suffix) -> not (Text.null host) && Text.all (\c -> digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c `elem` (":." :: String)) host && maybe False validPort (Text.stripPrefix "]" suffix)
        Nothing -> let (host, port) = Text.breakOn ":" hostPort in not (Text.null host) && Text.all validHost host && validPort port
  if Text.length value <= 2048 && validAuthority then Right (DirectEndpoint value) else Left InvalidEndpoint

serverId :: Text -> Either TargetError ServerId
serverId value = if uuid value then Right (ServerId value) else Left InvalidServerId

queryId :: Text -> Either TargetError QueryId
queryId value = if valid 128 (\c -> lowerDigit c || isAsciiUpper c || c `elem` ("_-" :: String)) value then Right (QueryId value) else Left InvalidQueryId

ledgerId :: Text -> Either TargetError LedgerId
ledgerId value = if uuid value then Right (LedgerId value) else Left InvalidLedgerId

ledgerNamespace :: Text -> Either TargetError LedgerNamespace
ledgerNamespace value
  | valid 128 (\c -> lowerDigit c || c == '_') value && maybe False (\(c, _) -> isAsciiLower c || c == '_') (Text.uncons value) = Right (LedgerNamespace value)
  | otherwise = Left InvalidLedgerNamespace

basicCredentials :: Text -> Text -> Either TargetError Credentials
basicCredentials user password
  | Text.null user || Text.any (`elem` (":\r\n\0" :: String)) user || Text.any (== '\0') password = Left InvalidCredentials
  | otherwise = Right (Credentials (Encoding.encodeUtf8 user) (Encoding.encodeUtf8 password))

-- | Deadline and raw-byte bound. Ordinary responses are bounded in total;
-- complete ledger reads apply this byte bound per JSON row (excluding LF).
-- Decoded history and reports still retain memory proportional to history size.
httpLimits :: Int -> Int -> Either TargetError HttpLimits
httpLimits timeoutMicros maxBytes
  | timeoutMicros > 0 && timeoutMicros <= 300000000 && maxBytes > 0 && maxBytes <= 16777216 = Right (HttpLimits timeoutMicros maxBytes)
  | otherwise = Left InvalidHttpLimits

defaultHttpLimits :: HttpLimits
defaultHttpLimits = HttpLimits 30000000 1048576

targetConfig :: TargetKey -> DirectEndpoint -> ServerId -> LedgerNamespace -> LedgerBinding -> Credentials -> HttpLimits -> TargetConfig
targetConfig = TargetConfig

targetKeyText :: TargetKey -> Text
targetKeyText (TargetKey value) = value

endpointText :: DirectEndpoint -> Text
endpointText (DirectEndpoint value) = value

serverIdText :: ServerId -> Text
serverIdText (ServerId value) = value

queryIdText :: QueryId -> Text
queryIdText (QueryId value) = value

ledgerIdText :: LedgerId -> Text
ledgerIdText (LedgerId value) = value

ledgerNamespaceText :: LedgerNamespace -> Text
ledgerNamespaceText (LedgerNamespace value) = value

valid :: Int -> (Char -> Bool) -> Text -> Bool
valid limit allowed value = not (Text.null value) && Text.length value <= limit && Text.all allowed value

lowerDigit :: Char -> Bool
lowerDigit c = isAsciiLower c || digit c

digit :: Char -> Bool
digit c = c >= '0' && c <= '9'

uuid :: Text -> Bool
uuid value = map Text.length (Text.splitOn "-" value) == [8, 4, 4, 4, 12] && Text.all (\c -> c == '-' || digit c || (c >= 'a' && c <= 'f')) value

identityServerId :: ServerIdentity -> ServerId
identityServerId (ServerIdentity value _ _) = value

identityVersion :: ServerIdentity -> Text
identityVersion (ServerIdentity _ value _) = value

identityHostName :: ServerIdentity -> Text
identityHostName (ServerIdentity _ _ value) = value

-- | Fresh client-generated UUID for a one-time first-use authorization. Persist
-- this value before submission and retain it after interrupted initialization.
newLedgerId :: IO LedgerId
newLedgerId = LedgerId <$> freshUuid

-- | Read-only nonsecret configuration identity for application adapters.
configuredTargetKey :: TargetConfig -> TargetKey
configuredTargetKey (TargetConfig key _ _ _ _ _ _) = key

-- | Binding mode is explicit; this accessor grants no initialization authority.
configuredLedgerBinding :: TargetConfig -> LedgerBinding
configuredLedgerBinding (TargetConfig _ _ _ _ binding _ _) = binding
