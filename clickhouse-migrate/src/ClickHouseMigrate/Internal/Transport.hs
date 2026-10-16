-- | Four-way request evidence. No unsuccessful result authorizes replay.
module ClickHouseMigrate.Internal.Transport where

import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (QueryId, ServerIdentity)
import Data.Aeson (Object)

data RequestKind = Command | JsonRows | JsonRowStream deriving stock (Eq, Show)

data ResponsePayload = CommandAccepted | Rows ![Object] deriving stock (Eq, Show)

data TransportErrorCode = AdministrativeAccessLost | InvalidRequest | ClientScopeFailed | ConnectionFailed | DeadlineExpired | ResponseInterrupted | ResponseTooLarge | UnexpectedResponse | ServerRejected | RedirectRejected | ServerIdentityMismatch | UnsupportedServer | CompletionPolicyMismatch | CleanupFailed | CleanupTimedOut
  deriving stock (Eq, Ord, Show)

-- Only safe structured diagnostics; raw server/HTTP exceptions are never rendered.
data TransportError = TransportError
  { code :: !TransportErrorCode,
    httpStatus :: !(Maybe Int),
    serverCode :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data TransportOutcome
  = NotSubmitted !TransportError
  | AcknowledgedSuccess !ResponsePayload
  | ObservedServerFailure !TransportError
  | SubmissionUncertain !TransportError
  deriving stock (Eq, Show)

data ScopeResult a = ScopeResult !(Either TransportError a) ![TransportError]
  deriving stock (Eq, Show)

-- Private capability constructed only after target admission in ServerPolicy.
data Transport = Transport !(QueryId -> RequestKind -> ByteString -> IO TransportOutcome) !ServerIdentity

request :: Transport -> QueryId -> RequestKind -> ByteString -> IO TransportOutcome
request (Transport submit _) = submit

transportIdentity :: Transport -> ServerIdentity
transportIdentity (Transport _ identity) = identity
