-- | Private ordered manifest parser and package/manifest-tree containment.
module ClickHouseMigrate.Embed.Manifest
  ( ManifestError (..),
    ManifestErrorCode (..),
    Manifest (..),
    ManifestMigration (..),
    ManifestStep (..),
    decodeManifest,
    loadComponentFiles,
    constructComponent,
  )
where

import ClickHouseMigrate
import ClickHouseMigrate.Prelude
import Control.Exception (Exception, IOException, throwIO, try)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.List (inits)
import Data.Set qualified as Set
import Data.Text qualified as Text
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (isAbsolute, joinPath, makeRelative, splitDirectories, takeDirectory, (</>))

data ManifestErrorCode = InvalidJson | DuplicateKey | UnknownField | MissingField | WrongType | UnsupportedManifestVersion | DuplicateDependency | UnsafePath | MissingFile | FileAccessFailure | InvalidDefinition
  deriving stock (Eq, Ord, Show)

data ManifestError = ManifestError
  { code :: !ManifestErrorCode,
    path :: ![Text],
    definitionError :: !(Maybe DefinitionError)
  }
  deriving stock (Eq, Show)

instance Exception ManifestError

data Manifest = Manifest !Text ![Text] ![ManifestMigration] deriving stock (Eq, Show)

data ManifestMigration = ManifestMigration !Text !(Maybe Text) ![ManifestStep] deriving stock (Eq, Show)

data ManifestStep = ManifestStep !Text !FilePath deriving stock (Eq, Show)

err :: ManifestErrorCode -> [Text] -> Either ManifestError a
err c p = Left (ManifestError c p Nothing)

-- Walk aeson's public token representation before it discards duplicate keys.
checkTokens :: [Text] -> Tokens k String -> Either ManifestError k
checkTokens _ (TkLit _ next) = Right next
checkTokens _ (TkText _ next) = Right next
checkTokens _ (TkNumber _ next) = Right next
checkTokens p (TkArrayOpen values) = checkArray p 0 values
checkTokens p (TkRecordOpen pairs) = checkRecord p Set.empty pairs
checkTokens p (TkErr _) = err InvalidJson p

checkArray :: [Text] -> Int -> TkArray k String -> Either ManifestError k
checkArray _ _ (TkArrayEnd next) = Right next
checkArray p _ (TkArrayErr _) = err InvalidJson p
checkArray p i (TkItem value) = checkTokens (p ++ [Text.pack (show i)]) value >>= checkArray p (i + 1)

checkRecord :: [Text] -> Set Key.Key -> TkRecord k String -> Either ManifestError k
checkRecord _ _ (TkRecordEnd next) = Right next
checkRecord p _ (TkRecordErr _) = err InvalidJson p
checkRecord p seen (TkPair key value)
  | Set.member key seen = err DuplicateKey (p ++ [Text.take 128 (Key.toText key)])
  | otherwise = checkTokens (p ++ [Text.take 128 (Key.toText key)]) value >>= checkRecord p (Set.insert key seen)

decodeManifest :: ByteString -> Either ManifestError Manifest
decodeManifest bytes = do
  _ <- checkTokens [] (bsToTokens bytes)
  value <- either (const (err InvalidJson [])) Right (eitherDecodeStrict' bytes)
  object <- objectAt [] ["manifestVersion", "component", "dependencies", "migrations"] value
  version <- required [] "manifestVersion" object
  case version of Number 1 -> Right (); _ -> err UnsupportedManifestVersion ["manifestVersion"]
  name <- required [] "component" object >>= textAt ["component"]
  deps <- required [] "dependencies" object >>= arrayAt ["dependencies"] >>= traverse (textAt ["dependencies"])
  if Set.size (Set.fromList deps) /= length deps then err DuplicateDependency ["dependencies"] else pure ()
  migrations <- required [] "migrations" object >>= arrayAt ["migrations"] >>= indexed parseMigration ["migrations"]
  pure (Manifest name deps migrations)
  where
    parseMigration p value = do
      object <- objectAt p ["name", "description", "steps"] value
      name <- required p "name" object >>= textAt (p ++ ["name"])
      description <- case KM.lookup "description" object of
        Nothing -> Right Nothing
        Just Null -> Right Nothing
        Just v -> Just <$> textAt (p ++ ["description"]) v
      steps <- required p "steps" object >>= arrayAt (p ++ ["steps"]) >>= indexed parseStep (p ++ ["steps"])
      pure (ManifestMigration name description steps)
    parseStep p value = do
      object <- objectAt p ["name", "file"] value
      name <- required p "name" object >>= textAt (p ++ ["name"])
      file <- required p "file" object >>= textAt (p ++ ["file"])
      pure (ManifestStep name (Text.unpack file))

indexed :: ([Text] -> a -> Either ManifestError b) -> [Text] -> [a] -> Either ManifestError [b]
indexed f p = traverse (\(i, value) -> f (p ++ [Text.pack (show i)]) value) . zip [0 :: Int ..]

objectAt :: [Text] -> [Key.Key] -> Value -> Either ManifestError (KM.KeyMap Value)
objectAt p allowed (Object object) = case filter (`notElem` allowed) (KM.keys object) of
  [] -> Right object
  key : _ -> err UnknownField (p ++ [Text.take 128 (Key.toText key)])
objectAt p _ _ = err WrongType p

required :: [Text] -> Key.Key -> KM.KeyMap Value -> Either ManifestError Value
required p key = maybe (err MissingField (p ++ [Key.toText key])) Right . KM.lookup key

textAt :: [Text] -> Value -> Either ManifestError Text
textAt _ (String text) = Right text
textAt p _ = err WrongType p

arrayAt :: [Text] -> Value -> Either ManifestError [Value]
arrayAt _ (Array values) = Right (toList values)
arrayAt p _ = err WrongType p

-- All IO is compile-time. Track both lexical and canonical paths for symlinks.
loadComponentFiles :: FilePath -> FilePath -> IO (Either ManifestError (Manifest, [(FilePath, ByteString)], [FilePath]))
loadComponentFiles packageRoot manifestFile = do
  outcome <- try @IOException (try @ManifestError load)
  pure $ case outcome of
    Left _ -> Left (ManifestError FileAccessFailure [Text.pack (take 256 manifestFile)] Nothing)
    Right result -> result
  where
    load = do
      root <- canonicalizePath packageRoot
      manifest <- containedFile root manifestFile
      bytes <- BS.readFile manifest
      parsed@(Manifest _ _ migrations) <- either throwIO pure (decodeManifest bytes)
      let directory = takeDirectory manifest
          files = [file | ManifestMigration _ _ steps <- migrations, ManifestStep _ file <- steps]
      loaded <-
        traverse
          ( \file -> do
              canonical <- containedFile directory file
              sql <- BS.readFile canonical
              pure (file, sql, [directory </> file, canonical])
          )
          files
      pure (parsed, [(file, sql) | (file, sql, _) <- loaded], [root </> manifestFile, manifest] ++ concat [paths | (_, _, paths) <- loaded])

containedFile :: FilePath -> FilePath -> IO FilePath
containedFile root relative = do
  let parts = splitDirectories relative
      unsafe = null relative || isAbsolute relative || any (== "..") parts || '\\' `elem` relative || '\0' `elem` relative
      reject = throwIO (ManifestError UnsafePath [Text.pack (take 256 relative)] Nothing)
      inside path = not (isAbsolute (makeRelative root path)) && not (".." `elem` splitDirectories (makeRelative root path))
  if unsafe then reject else pure ()
  -- Inspect every ancestor: a symlink may escape and later return inside.
  mapM_
    ( \prefix -> do
        canonical <- canonicalizePath (root </> joinPath prefix)
        unless (inside canonical) reject
    )
    (drop 1 (inits parts))
  canonical <- canonicalizePath (root </> relative)
  exists <- doesFileExist canonical
  unless exists (throwIO (ManifestError MissingFile [Text.pack (take 256 relative)] Nothing))
  pure canonical

constructComponent :: Manifest -> [(FilePath, ByteString)] -> Either ManifestError MigrationComponent
constructComponent (Manifest name deps migrations) sources = do
  definitions <- traverse buildMigration migrations
  core ["component"] (migrationComponentFromList name (Set.fromList deps) definitions)
  where
    core p = either (\e -> Left (ManifestError InvalidDefinition p (Just e))) Right
    buildMigration (ManifestMigration migration description steps) = do
      definitions <- traverse (buildStep migration) steps
      withMigrationDescription description <$> core ["migrations", Text.take 128 migration] (sqlMigrationFromList migration definitions)
    buildStep migration (ManifestStep step file) = case lookup file sources of
      Nothing -> err MissingFile [Text.pack file]
      Just bytes -> core ["migrations", Text.take 128 migration, "steps", Text.take 128 step, Text.pack (take 256 file)] (sqlStep step bytes)
