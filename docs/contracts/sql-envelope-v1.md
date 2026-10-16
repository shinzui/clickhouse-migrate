# SQL envelope v1

Each step is exact UTF-8 bytes with no NUL. Validation scans boundaries without
rewriting SQL. The server still validates SQL grammar and semantics; accepted
input does not prove application safety or completion on an unqualified server.
Errors contain a code, definition path and optional zero-based Unicode character
offset. They never include the SQL body.

The scanner recognizes single-quoted strings, double-quoted/backtick identifiers,
doubled delimiters and backslash escapes. Quoted identifiers accept escaped
backslash or their delimiter; other identifier escapes are rejected. Strings may
contain backslash-escaped characters. Heredocs use `$$...$$` or a matching
`$tag$...$tag$`, with ASCII letter/underscore followed by ASCII letters, digits
or underscores. Contents are literal. Unterminated constructs fail validation.
Line comments begin with `--`, `//`, `#!` or `# `; block comments use `/*...*/`
and may nest. One trailing semicolon and trailing comments are accepted. Any
second separator or token after a separator is rejected.

The allowlist accepts CREATE TABLE/VIEW/MATERIALIZED VIEW/DATABASE,
DROP TABLE/VIEW/DATABASE, TRUNCATE TABLE, RENAME TABLE, ALTER TABLE, and
INSERT INTO a table with a SELECT or VALUES body. Table/view names in the command
header must have a database qualifier, including individually quoted names.
Database DDL names one database. Optional IF EXISTS/IF NOT EXISTS clauses are
recognized. CREATE OR REPLACE, temporary tables, standalone SELECT, lightweight
DELETE and administrative/session/transaction commands are outside v1.

ALTER TABLE must begin with ADD, DROP, CLEAR, MODIFY, RENAME, COMMENT,
MATERIALIZE, UPDATE, DELETE or REMOVE. Operations with ATTACH, DETACH, FETCH,
FREEZE, UNFREEZE, MOVE or REPLACE tokens are excluded. Detached REFRESH, ASYNC,
WATCH, LIVE and WINDOW forms are excluded throughout. The lexer cannot prove
all ALTER subcommand semantics; the author must restrict them to response-bound
local DDL/mutations qualified by the server matrix.

Outside literals/quoted identifiers, FORMAT, INFILE, OUTFILE, REMOTE,
REMOTESECURE and DISTRIBUTED are rejected, as are engine names beginning with
REPLICATED. Known remote/replicated engine names are also rejected when quoted.
ON followed by CLUSTER is rejected even with intervening comments.
Client backslash directives and ambiguous dollar/hash/unsupported characters
outside literals are rejected. Unsupported SQL should be reauthored as supported
steps, rather than bypassing the validator.

The protected identifiers `async_insert`, `mutations_sync` and `alter_sync`
are rejected case-insensitively, including quoted spellings. This deliberately
rejects even an application column with the same spelling. Quoted or literal
assignment keys after SETTINGS are excluded, closing escape-based setting-name
aliases. Runtime configuration must apply async_insert=0, mutations_sync=1 and
alter_sync=1; those exact policy bytes participate in checksums.

This is a conservative envelope, not a complete SQL parser. A keyword used as an
unquoted application identifier can be rejected; authors may need different names
or supported quoted identifiers. The author must review every referenced object,
nested query/function, table engine and later ALTER action: all application
objects must be qualified, writes must remain on the pinned server, and SQL must
never touch the ledger database, use remote/distributed write paths, or merely
schedule detached work. Engine aliases, view targets and arbitrary expressions
cannot be proven safe by this lexer. Adoption review carries the same obligation.

The comment/literal forms were checked against the official
[ClickHouse syntax reference](https://clickhouse.com/docs/reference/syntax) on
2026-10-16. EP-4 must qualify these forms and accepted completion cases against
its selected server matrix before claiming runtime support. In particular, a
lexically accepted materialized view must not have a detached refresh policy.
