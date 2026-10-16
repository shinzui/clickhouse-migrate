{-# LANGUAGE MultilineStrings #-}

-- | Exact local v1 physical shape; never infer uniqueness from the sorting key.
module ClickHouseMigrate.Internal.LedgerSchema where

import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (LedgerNamespace, ledgerNamespaceText)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

quoteIdentifier :: Text -> Text
quoteIdentifier value = "`" <> Text.replace "`" "``" value <> "`"

qualifiedTable :: LedgerNamespace -> Text
qualifiedTable namespace = quoteIdentifier (ledgerNamespaceText namespace) <> ".`events`"

createDatabase :: LedgerNamespace -> ByteString
createDatabase namespace = Encoding.encodeUtf8 ("CREATE DATABASE IF NOT EXISTS " <> quoteIdentifier (ledgerNamespaceText namespace) <> " ENGINE=Atomic")

createTable :: LedgerNamespace -> ByteString
createTable namespace = Encoding.encodeUtf8 ("CREATE TABLE IF NOT EXISTS " <> qualifiedTable namespace <> " " <> columnsSql <> " ENGINE=MergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'")

columnsSql :: Text
columnsSql = "(sequence UInt64, event_id UUID, ledger_id UUID, event String)"

expectedCreate :: LedgerNamespace -> Text
expectedCreate namespace = "CREATE TABLE " <> ledgerNamespaceText namespace <> ".events (`sequence` UInt64, `event_id` UUID, `ledger_id` UUID, `event` String) ENGINE = " <> expectedEngine

expectedEngine :: Text
expectedEngine = "MergeTree ORDER BY sequence SETTINGS fsync_after_insert = 1, fsync_part_directory = 1, storage_policy = 'default', index_granularity = 8192"

-- Only validated ASCII namespace names enter literals; event/audit data are JSON.
namespaceLiteral :: LedgerNamespace -> Text
namespaceLiteral = (\value -> "'" <> value <> "'") . ledgerNamespaceText

databaseQuery :: LedgerNamespace -> ByteString
databaseQuery namespace = Encoding.encodeUtf8 ("SELECT name, engine FROM system.databases WHERE name=" <> namespaceLiteral namespace)

tableQuery :: LedgerNamespace -> ByteString
tableQuery namespace = Encoding.encodeUtf8 ("SELECT name, engine, engine_full, sorting_key, primary_key, partition_key, sampling_key, create_table_query FROM system.tables WHERE database=" <> namespaceLiteral namespace <> " ORDER BY name")

readQuery :: LedgerNamespace -> ByteString
readQuery namespace = Encoding.encodeUtf8 ("SELECT toString(sequence) AS sequence, toString(event_id) AS event_id, toString(ledger_id) AS ledger_id, event FROM " <> qualifiedTable namespace <> " ORDER BY sequence, event_id")
