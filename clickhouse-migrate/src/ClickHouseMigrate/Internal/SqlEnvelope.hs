-- | Conservative lexical envelope; never a general SQL safety proof.
module ClickHouseMigrate.Internal.SqlEnvelope (validateSql, mentionsIdentifier) where

import ClickHouseMigrate.Error
import ClickHouseMigrate.Prelude
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, toUpper)
import Data.List (find, isPrefixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

data Kind = Word !Text | Identifier !Text | Literal | Symbol !Char
  deriving stock (Eq, Show)

data Token = Token !Int !Kind deriving stock (Eq, Show)

failure :: DefinitionErrorCode -> Maybe Int -> Either DefinitionError a
failure c offset = Left (DefinitionError c ["sql"] offset)

validateSql :: ByteString -> Either DefinitionError ()
validateSql sql = do
  text <- either (const (failure InvalidUtf8 Nothing)) Right (Encoding.decodeUtf8' sql)
  if BS.elem 0 sql then failure NulInSql Nothing else pure ()
  tokens <- scan 0 (Text.unpack text)
  statement <- case break (\(Token _ k) -> k == Symbol ';') tokens of
    (xs, []) -> Right xs
    (xs, [_]) -> Right xs
    (_, Token n _ : _) -> failure MultipleStatements (Just n)
  case statement of
    [] -> failure EmptySql Nothing
    _ -> checkEnvelope statement

scan :: Int -> String -> Either DefinitionError [Token]
scan _ [] = Right []
scan n input@(c : cs)
  | c `elem` [' ', '\t', '\r', '\n', '\f'] = scan (n + 1) cs
  | "--" `isPrefixOf` input || "//" `isPrefixOf` input = lineComment
  | "#!" `isPrefixOf` input || "# " `isPrefixOf` input = lineComment
  | "/*" `isPrefixOf` input = do
      (used, rest) <- block n 1 2 (drop 2 input)
      scan (n + used) rest
  | c == '\'' || c == '"' || c == '`' = do
      (used, value, rest) <- quoted n c 1 [] cs
      let kind = if c == '\'' then Literal else Identifier (Text.pack (map toUpper value))
      (Token n kind :) <$> scan (n + used) rest
  | c == '$' = do
      let (tag, end) = span wordChar cs
      case end of
        '$' : rest | case tag of [] -> True; first : _ -> firstName first -> do
          let delimiter = '$' : tag ++ "$"
          (used, remaining) <- heredoc n delimiter (length delimiter) rest
          (Token n Literal :) <$> scan (n + used) remaining
        _ -> failure UnsupportedSql (Just n)
  | wordChar c =
      let (word, rest) = span wordChar input
       in (Token n (Word (Text.pack (map toUpper word))) :) <$> scan (n + length word) rest
  | c `elem` ("(),.;=+-*/%<>![]:{}?|&^~" :: String) = (Token n (Symbol c) :) <$> scan (n + 1) cs
  | otherwise = failure UnsupportedSql (Just n)
  where
    lineComment = let (comment, rest) = break (`elem` ['\r', '\n']) input in scan (n + length comment) rest

firstName :: Char -> Bool
firstName c = isAsciiLower c || isAsciiUpper c || c == '_'

wordChar :: Char -> Bool
wordChar c = firstName c || (c >= '0' && c <= '9')

block :: Int -> Int -> Int -> String -> Either DefinitionError (Int, String)
block start depth used input
  | "/*" `isPrefixOf` input = block start (depth + 1) (used + 2) (drop 2 input)
  | "*/" `isPrefixOf` input = if depth == 1 then Right (used + 2, drop 2 input) else block start (depth - 1) (used + 2) (drop 2 input)
block start _ _ [] = failure UnterminatedSql (Just start)
block start depth used (_ : rest) = block start depth (used + 1) rest

quoted :: Int -> Char -> Int -> String -> String -> Either DefinitionError (Int, String, String)
quoted start _ _ _ [] = failure UnterminatedSql (Just start)
quoted start quote used acc (c : rest)
  | c == quote = case rest of
      d : remaining | d == quote -> quoted start quote (used + 2) (quote : acc) remaining
      _ -> Right (used + 1, reverse acc, rest)
  | c == '\\' = case rest of
      [] -> failure UnterminatedSql (Just start)
      d : remaining
        | quote == '\'' || d `elem` [quote, '\\'] -> quoted start quote (used + 2) (d : acc) remaining
        -- Unfamiliar quoted-identifier escapes are outside the envelope.
        | otherwise -> failure UnsupportedSql (Just (start + used))
  | otherwise = quoted start quote (used + 1) (c : acc) rest

heredoc :: Int -> String -> Int -> String -> Either DefinitionError (Int, String)
heredoc _start delimiter used input
  | delimiter `isPrefixOf` input = Right (used + length delimiter, drop (length delimiter) input)
heredoc start _ _ [] = failure UnterminatedSql (Just start)
heredoc start delimiter used (_ : rest) = heredoc start delimiter (used + 1) rest

keyword :: Text -> Token -> Bool
keyword word (Token _ kind) = kind == Word word

isName :: Token -> Bool
isName (Token _ (Word w)) = maybe False (firstName . fst) (Text.uncons w)
isName (Token _ (Identifier _)) = True
isName _ = False

-- Objects in the command header must be qualified; deeper expressions remain
-- author obligations. Database DDL itself has a single database name.
qualifiedTarget :: [Token] -> Maybe [Token]
qualifiedTarget (a : Token _ (Symbol '.') : b : rest) | isName a && isName b = Just rest
qualifiedTarget _ = Nothing

skipIf :: [Token] -> [Token]
skipIf (a : b : c : rest) | and [keyword "IF" a, keyword "NOT" b, keyword "EXISTS" c] = rest
skipIf (a : b : rest) | keyword "IF" a && keyword "EXISTS" b = rest
skipIf rest = rest

checkEnvelope :: [Token] -> Either DefinitionError ()
checkEnvelope tokens = do
  case find protected tokens of
    Just (Token n _) -> failure ProtectedSetting (Just n)
    Nothing -> pure ()
  case find forbidden (localViewHeader tokens) of
    Just (Token n _) -> failure UnsupportedSql (Just n)
    Nothing -> pure ()
  if any onCluster (pairs tokens) || quotedSettings tokens then failure UnsupportedSql Nothing else pure ()
  if accepted (localViewHeader tokens) then Right () else failure UnsupportedSql (case tokens of Token n _ : _ -> Just n; _ -> Nothing)
  where
    protected (Token _ (Word w)) = w `elem` protectedNames
    protected (Token _ (Identifier w)) = w `elem` protectedNames
    protected _ = False
    forbidden (Token _ (Word w)) = w `elem` forbiddenWords || "REPLICATED" `Text.isPrefixOf` w
    forbidden (Token _ (Identifier w)) = w `elem` ["DISTRIBUTED", "REMOTE", "REMOTESECURE"] || "REPLICATED" `Text.isPrefixOf` w
    forbidden _ = False
    onCluster (a, b) = keyword "ON" a && keyword "CLUSTER" b
    quotedSettings xs = case dropWhile (not . keyword "SETTINGS") xs of
      [] -> False
      _ : rest -> any quotedAssignment (pairs rest)
    quotedAssignment (Token _ (Identifier _), Token _ (Symbol '=')) = True
    quotedAssignment (Token _ Literal, Token _ (Symbol '=')) = True
    quotedAssignment _ = False

-- Only this exact local view header permits REPLACE. ALTER replacement,
-- CREATE OR REPLACE TABLE and later REPLACE tokens remain excluded.
localViewHeader :: [Token] -> [Token]
localViewHeader (create : orToken : replace : view : rest)
  | and [keyword "CREATE" create, keyword "OR" orToken, keyword "REPLACE" replace, keyword "VIEW" view] = create : view : rest
localViewHeader tokens = tokens

protectedNames :: [Text]
protectedNames = ["ASYNC_INSERT", "MUTATIONS_SYNC", "ALTER_SYNC"]

forbiddenWords :: [Text]
forbiddenWords =
  [ "FORMAT",
    "INFILE",
    "OUTFILE",
    "ASYNC",
    "REFRESH",
    "WATCH",
    "REMOTE",
    "REMOTESECURE",
    "DISTRIBUTED",
    "ATTACH",
    "DETACH",
    "FETCH",
    "FREEZE",
    "UNFREEZE",
    "MOVE",
    "REPLACE",
    "LIVE",
    "WINDOW"
  ]

pairs :: [a] -> [(a, a)]
pairs xs = zip xs (drop 1 xs)

accepted :: [Token] -> Bool
accepted (a : b : rest)
  | keyword "CREATE" a = create (b : rest)
  | keyword "ALTER" a && keyword "TABLE" b = case qualifiedTarget (skipIf rest) of
      Just (action : _) -> any (`keyword` action) ["ADD", "DROP", "CLEAR", "MODIFY", "RENAME", "COMMENT", "MATERIALIZE", "UPDATE", "DELETE", "REMOVE"]
      _ -> False
  | keyword "DROP" a = object b (skipIf rest)
  | keyword "TRUNCATE" a && keyword "TABLE" b = maybe False (const True) (qualifiedTarget (skipIf rest))
  | keyword "EXCHANGE" a && keyword "TABLES" b = case qualifiedTarget rest of
      Just (andToken : second) | keyword "AND" andToken -> qualifiedTarget second == Just []
      _ -> False
  | keyword "RENAME" a && keyword "TABLE" b = maybe False (const True) (qualifiedTarget rest)
  | keyword "INSERT" a && keyword "INTO" b = case qualifiedTarget rest of
      Just body -> any (\t -> keyword "SELECT" t || keyword "VALUES" t) body
      _ -> False
  where
    create (kind : body) | keyword "MATERIALIZED" kind = case body of
      view : target | keyword "VIEW" view -> maybe False (const True) (qualifiedTarget (skipIf target))
      _ -> False
    create (kind : body) = object kind (skipIf body)
    create [] = False
    object kind body
      | keyword "TABLE" kind || keyword "VIEW" kind = maybe False (const True) (qualifiedTarget body)
      | keyword "DATABASE" kind = case body of name : _ -> isName name; _ -> False
      | otherwise = False
accepted _ = False

-- Runtime ledger namespace isolation reuses the SAME literal/comment-aware scan.
-- Quoted compound identifiers are conservatively split at dots. This is an
-- identifier reservation, not a proof about arbitrary deeper SQL expressions.
mentionsIdentifier :: Text -> ByteString -> Either DefinitionError Bool
mentionsIdentifier name sql = do
  text <- either (const (failure InvalidUtf8 Nothing)) Right (Encoding.decodeUtf8' sql)
  tokens <- scan 0 (Text.unpack text)
  let wanted = Text.toUpper name
      matches (Token _ (Word value)) = wanted == value
      matches (Token _ (Identifier value)) = wanted `elem` Text.splitOn "." value
      matches _ = False
  pure (any matches tokens)
