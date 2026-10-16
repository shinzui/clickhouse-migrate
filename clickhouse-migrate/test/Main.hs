module Main (main) where

import ClickHouseMigrate
import ClickHouseMigrate.Internal.Checksum qualified as Checksum
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.IO qualified as Text
import Numeric (readHex)

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

isDefinitionError :: DefinitionErrorCode -> Either DefinitionError a -> Bool
isDefinitionError expected (Left (DefinitionError actual _ _)) = expected == actual
isDefinitionError _ _ = False

isPlanError :: PlanErrorCode -> Either PlanError a -> Bool
isPlanError expected (Left (PlanError actual _)) = expected == actual
isPlanError _ _ = False

main :: IO ()
main = do
  targetValidation
  let sql = "CREATE TABLE app.events (id UInt64) ENGINE=MergeTree ORDER BY id"
  create <- right (sqlStep "create" sql)
  migration <- right (sqlMigration "0001" (create :| []))
  a <- right (migrationComponent "a" Set.empty (migration :| []))
  b <- right (migrationComponent "b" (Set.singleton "a") (migration :| []))
  plan <- right (migrationPlan (a :| [b]))
  assert "caller order preserved" (map (componentNameText . componentViewName) (NE.toList (inspectPlan plan)) == ["a", "b"])
  assert "component-bound checksums differ" (map (migrationChecksumHex . migrationChecksum . NE.head . componentMigrations) (NE.toList (inspectPlan plan)) /= replicate 2 (migrationChecksumHex (migrationChecksum (NE.head (componentMigrations (NE.head (inspectPlan plan)))))))
  assert "duplicate components" (isPlanError DuplicateComponent (migrationPlan (a :| [a])))
  assert "late dependency" (isPlanError DependencyAfterDependent (migrationPlan (b :| [a])))
  assert "missing dependency" (isPlanError MissingDependency (migrationPlan (b :| [])))
  self <- right (migrationComponent "a" (Set.singleton "a") (migration :| []))
  assert "self dependency" (isPlanError SelfDependency (migrationPlan (self :| [])))
  cycleA <- right (migrationComponent "a" (Set.singleton "b") (migration :| []))
  assert "cycle" (isPlanError DependencyCycle (migrationPlan (cycleA :| [b])))
  assert "duplicate steps" (isDefinitionError DuplicateName (sqlMigration "0001" (create :| [create])))
  assert "duplicate migrations" (isDefinitionError DuplicateName (migrationComponent "a" Set.empty (migration :| [migration])))
  assert "empty steps" (isDefinitionError EmptyCollection (sqlMigrationFromList "0001" []))
  assert "empty migrations" (isDefinitionError EmptyCollection (migrationComponentFromList "a" Set.empty []))
  assert "empty components" (isPlanError EmptyPlan (migrationPlanFromList []))
  forM_ [0 .. 255] $ \n -> do
    let c = chr n
        valid = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    assert ("single-character name " ++ show n) (either (const False) (const True) (stepName (Text.singleton c)) == valid)
  forM_ ["", "A", "a.b", "a/b", "_a", "-a", "雪", "a b", Text.replicate 129 "a"] $ \name ->
    assert "invalid name" (isDefinitionError InvalidName (sqlStep name sql))
  _ <- right (sqlStep (Text.replicate 128 "a") sql)
  forM_ ["", " \n\t", "-- comment", "/* outer /* inner */ end */", "# comment\n// comment", ";"] $ \empty ->
    assert "empty/comment-only SQL" (isDefinitionError EmptySql (sqlStep "x" empty))
  assert "invalid UTF-8" (isDefinitionError InvalidUtf8 (sqlStep "x" (BS.pack [255])))
  assert "NUL" (isDefinitionError NulInSql (sqlStep "x" (sql <> BS.singleton 0)))
  forM_ ["CREATE TABLE app.t (x UInt8); DROP TABLE app.t", "CREATE TABLE app.t (x UInt8);;", "INSERT INTO app.t VALUES ('a'); INSERT INTO app.t VALUES ('b')"] $ \multiple ->
    assert "multiple SQL statements" (isDefinitionError MultipleStatements (sqlStep "x" multiple))
  forM_ ["INSERT INTO app.t VALUES ('open", "INSERT INTO app.t VALUES ($x$open)", "CREATE TABLE app.t (x UInt8) /*", "CREATE TABLE app.\"t (x UInt8)"] $ \unterminated ->
    assert "unterminated SQL construct" (isDefinitionError UnterminatedSql (sqlStep "x" unterminated))
  forM_ ["BEGIN", "COMMIT", "ROLLBACK", "USE app", "SET x=1", "SELECT 1", "SYSTEM FLUSH LOGS", "CREATE TABLE app.t ON /* gap */ CLUSTER c (x UInt8)", "INSERT INTO app.t FORMAT CSV\n1", "CREATE MATERIALIZED VIEW app.v REFRESH EVERY 1 SECOND AS SELECT 1", "ALTER TABLE app.t MOVE PARTITION 1 TO TABLE app.other", "CREATE TABLE app.t ENGINE=ReplicatedMergeTree ORDER BY tuple()", "CREATE TABLE unqualified (x UInt8)", "\\i file.sql"] $ \unsupported ->
    assert "unsupported SQL" (isDefinitionError UnsupportedSql (sqlStep "x" unsupported))
  forM_ ["async_insert", "mutations_sync", "alter_sync", "AsYnC_InSeRt", "`alter_sync`", "\"mutations_sync\""] $ \setting ->
    assert "protected setting" (isDefinitionError ProtectedSetting (sqlStep "x" (Encoding.encodeUtf8 ("INSERT INTO app.t VALUES (1) SETTINGS " <> setting <> " /*comment*/ = 0"))))
  forM_ ["INSERT INTO app.t VALUES ('a; b')", "INSERT INTO app.t VALUES ('a'';b')", "INSERT INTO app.t VALUES ('a\\';b')", "INSERT INTO app.t VALUES ($tag$a; ' \\ $tag$)", "INSERT INTO app.t VALUES ($$a; b$$)", "CREATE TABLE app.\"t;\" (`x;` UInt8)", "CREATE TABLE app.\"t\\\";\" (x UInt8)", "CREATE TABLE app.t (x UInt8) /* outer; /* inner; */ end; */; -- tail;", "INSERT INTO app.t VALUES (1) // ; ignored\n; #! tail;", "ALTER TABLE app.t ADD COLUMN x UInt8", "ALTER TABLE app.t UPDATE x=1 WHERE x=0", "INSERT INTO app.t SELECT 1", "DROP TABLE IF EXISTS app.t", "CREATE DATABASE app", "CREATE MATERIALIZED VIEW app.v TO app.t AS SELECT * FROM app.s"] $ \valid -> do
    step <- right (sqlStep "x" valid)
    m <- right (sqlMigration "m" (step :| []))
    c <- right (migrationComponent "c" Set.empty (m :| []))
    p <- right (migrationPlan (c :| []))
    assert "SQL exact bytes preserved" (stepSql (NE.head (migrationSteps (NE.head (componentMigrations (NE.head (inspectPlan p)))))) == valid)
  -- Boundary combinations cover escaped delimiters, comment forms and heredoc tags.
  forM_ [";", "'; DROP TABLE app.t; --", "/* ; */", "雪;", "\\;", "# ;"] $ \payload ->
    forM_ ["tag", "other", "_x9"] $ \tag -> do
      _ <- right (sqlStep "x" (Encoding.encodeUtf8 ("INSERT INTO app.t VALUES ($" <> tag <> "$" <> payload <> "$" <> tag <> "$); /* ; */")))
      pure ()
  described <- right (migrationComponent "a" Set.empty (withMigrationDescription (Just "metadata") migration :| []))
  describedPlan <- right (migrationPlan (described :| []))
  let firstMigration = NE.head . componentMigrations . NE.head . inspectPlan
  assert "description excluded from checksum" (migrationChecksum (firstMigration plan) == migrationChecksum (firstMigration describedPlan))
  assert "description available" (migrationDescription (firstMigration describedPlan) == Just "metadata")
  assert "unknown checksum format" (isDefinitionError UnknownChecksumFormat (parseChecksumFormat "sha256-v2"))
  assert "known checksum format" (parseChecksumFormat "sha256-v1" == Right ChecksumV1)
  vectorLines <- filter (not . Text.isPrefixOf "#") . Text.lines <$> Text.readFile "test/vectors/checksum-v1.tsv"
  forM_ vectorLines checkVector
  putStrLn "Definition, ordering, SQL boundary and 24 independent checksum-vector checks passed."

checkVector :: Text -> IO ()
checkVector line = case Text.splitOn "\t" line of
  [label, kind, component, name, sources, expectedInput, expectedDigest] -> do
    steps <- mapM parseStep (Text.splitOn "," sources)
    let encodedSteps = fmap (\(key, sql) -> Checksum.encodeStepV1 component name key sql) (NE.fromList steps)
        input = if kind == "step" then NE.head encodedSteps else Checksum.encodeMigrationV1 component name (NE.toList encodedSteps)
    expected <- unhex expectedInput
    assert (Text.unpack (label <> " encoded bytes")) (input == expected)
    assert (Text.unpack (label <> " SHA-256")) (Checksum.digestHex (Checksum.digest input) == expectedDigest)
    authored <- mapM (\(key, sql) -> right (sqlStep key sql)) steps
    m <- right (sqlMigrationFromList name authored)
    c <- right (migrationComponent component Set.empty (m :| []))
    p <- right (migrationPlan (c :| []))
    let bound = NE.head (componentMigrations (NE.head (inspectPlan p)))
        actual = if kind == "step" then stepChecksumHex (stepChecksum (NE.head (migrationSteps bound))) else migrationChecksumHex (migrationChecksum bound)
    assert (Text.unpack (label <> " public bound checksum")) (actual == expectedDigest)
  _ -> fail "Invalid checked-in checksum vector"
  where
    parseStep source = case Text.splitOn ":" source of
      [key, hex] -> (key,) <$> unhex hex
      _ -> fail "Invalid step in checksum vector"

unhex :: Text -> IO ByteString
unhex text = BS.pack <$> go (Text.unpack text)
  where
    go [] = pure []
    go (a : b : rest) = case readHex [a, b] of
      [(byte, "")] -> (byte :) <$> go rest
      _ -> fail "Invalid vector hex"
    go _ = fail "Odd vector hex length"

-- Public parsing boundaries must reject URL credentials and reserved overrides.
targetValidation :: IO ()
targetValidation = do
  forM_ ["http://localhost:8123", "https://example.com/", "http://[::1]:8123"] $ \value -> do
    _ <- right (directEndpoint value)
    pure ()
  forM_ ["", "ftp://localhost", "http://user:secret@localhost", "http://localhost/path", "http://localhost?async_insert=1", "http://localhost#fragment", "http://localhost:0", "http://localhost:65536", "http://localhost//", "http://"] $ \value ->
    assert "reject unsafe endpoint" (directEndpoint value == Left InvalidEndpoint)
  forM_ ["00000000-0000-0000-0000-000000000000", "01234567-89ab-cdef-0123-456789abcdef"] $ \value -> do
    _ <- right (serverId value)
    _ <- right (ledgerId value)
    pure ()
  forM_ ["", "01234567-89AB-cdef-0123-456789abcdef", "0123456789ab-cdef-0123-456789abcdef"] $ \value ->
    assert "canonical UUID required" (serverId value == Left InvalidServerId)
  assert "invalid request bounds" (either (== InvalidHttpLimits) (const False) (httpLimits 0 1))
  assert "bounded response allocation" (either (== InvalidHttpLimits) (const False) (httpLimits 1 16777217))
  assert "credential header injection" (either (== InvalidCredentials) (const False) (basicCredentials "user\r\nheader" "password"))
  assert "namespace cannot inject SQL" (ledgerNamespace "ledger; DROP DATABASE app" == Left InvalidLedgerNamespace)
