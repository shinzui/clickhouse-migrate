-- | Private target representations. No caller-supplied Manager or Request.
module ClickHouseMigrate.Internal.TargetTypes where

import ClickHouseMigrate.Prelude

data TargetKey = TargetKey !Text deriving stock (Eq, Ord, Show)

data DirectEndpoint = DirectEndpoint !Text deriving stock (Eq, Show)

data ServerId = ServerId !Text deriving stock (Eq, Ord, Show)

data QueryId = QueryId !Text deriving stock (Eq, Ord, Show)

data LedgerId = LedgerId !Text deriving stock (Eq, Ord, Show)

data LedgerNamespace = LedgerNamespace !Text deriving stock (Eq, Ord, Show)

data LedgerBinding = FirstUse | ExistingLedger !LedgerId deriving stock (Eq, Show)

data Credentials = Credentials !ByteString !ByteString

data HttpLimits = HttpLimits !Int !Int deriving stock (Eq, Show)

data TargetConfig = TargetConfig !TargetKey !DirectEndpoint !ServerId !LedgerNamespace !LedgerBinding !Credentials !HttpLimits

data ServerIdentity = ServerIdentity !ServerId !Text !Text deriving stock (Eq, Show)
