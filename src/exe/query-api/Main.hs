module Main where

import Control.Concurrent.STM (readTVarIO)
import Control.Monad.Logger (runNoLoggingT, runStdoutLoggingT)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Maybe (fromMaybe)
import Data.String (IsString (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Database.Persist.Postgresql (createPostgresqlPool)
import Network.Wai.Handler.Warp
import Palmares.Metrics.Catalog (resolvedMetricCatalog)
import Palmares.WebAPI.CORS (getCorsConfigFromEnv)
import Palmares.WebAPI.Utils (requirePgConnStr, getPortFromEnvOrDefault)
import Query.Gov
  ( amberLagFromEnv,
    expectedNetworkFromEnv,
    freshnessPollMsFromEnv,
    readyMaxLagFromEnv,
    startFreshnessPoll,
  )
import Query.Refresh (runRefreshThread)
import Query.Views (applyPalmaresSchema)
import QueryAppMonad (QueryAppContext (..))
import RestAPI (apiSwagger, mkWebApp)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die, exitSuccess)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)


-- | Show only the host and dbname fields of a Postgres DSN, hiding the password.
redactConnStr :: String -> String
redactConnStr s =
  unwords [kv | kv <- words s, let k = takeWhile (/= '=') kv, k `elem` ["host", "dbname", "port"]]

-- | The generated Swagger document: committed, and the frontend's @gen:api@ input.
--
-- ONE producer, and that is the point. It used to be written on every boot, AFTER config and pool
-- creation, which meant CI could only obtain it by starting a server against a database.
swaggerPath :: FilePath
swaggerPath = "docs/generated/swagger/query-swagger-api.json"

-- | @--write-swagger-only@: write the document and exit.
--
-- It runs before anything else and touches NOTHING — no @PG_CONN_STR@, no pool, no @palmares@
-- schema, no port, not even the metric catalog — because 'apiSwagger' is a pure value derived from
-- the served API type. That is exactly what makes the CI parity guard runnable: no Postgres
-- service, no secrets, no listening socket.
writeSwagger :: IO ()
writeSwagger = do
  BL8.writeFile swaggerPath (encodePretty apiSwagger)
  putStrLn ("Wrote " <> swaggerPath)

-- | Boot order is the contract, and every step before 'runSettings' is fail-closed.
--
-- There is no Cardano provider here. This service reads @palmares@ views over db-sync and nothing
-- else (D-1), so it needs a Postgres DSN and no provider key — one fewer secret on a public read
-- path, and the reason the smoke script can run anywhere.
main :: IO ()
main = do
  -- Line-buffer stdout. GHC block-buffers it when it is not a TTY, which is exactly the case
  -- under Docker and Kubernetes: every line below would sit in a 8 KiB buffer until something
  -- else filled it, so an operator watching `kubectl logs` during a boot sees nothing at all.
  -- Measured here: piping the process hid all six boot lines while the server was already
  -- serving requests.
  hSetBuffering stdout LineBuffering

  args <- getArgs
  case args of
    ["--write-swagger-only"] -> writeSwagger >> exitSuccess
    _ -> serve

serve :: IO ()
serve = do

  -- Fail closed on the catalog before anything else touches the network: a malformed
  -- metric-formulas.json or a sql_file with no embed means /metrics/formulas would publish a
  -- formula nobody can read, and every metric id a response carries would resolve to nothing.
  case resolvedMetricCatalog of
    Left e -> die e
    Right fs -> putStrLn ("Metric catalog: " <> show (length fs) <> " formulas")

  corsCfg <- getCorsConfigFromEnv
  connStr <- requirePgConnStr
  pool <- runStdoutLoggingT $ createPostgresqlPool (T.encodeUtf8 (T.pack connStr)) 10

  -- The `palmares` schema is applied at BOOT, by this process, in one transaction, and the
  -- process dies if it fails (Query.Views). Every object in it is a view over db-sync, so there
  -- is no state to migrate: 000_schema.sql drops and re-creates the schema and the rest rebuild
  -- its contents. That makes the bootstrap idempotent, and it makes a db-sync upgrade that
  -- CASCADE-dropped our views self-healing on restart.
  --
  -- A SECOND pool, on its own DSN, because applying DDL and refreshing a matview need owner
  -- rights while every request should be served by a read-only role. PALMARES_PG_OWNER_CONN_STR
  -- defaults to PG_CONN_STR so a single-role deployment works unchanged; setting it is what
  -- separates the two once the roles exist.
  ownerConnStr <- fromMaybe connStr <$> lookupEnv "PALMARES_PG_OWNER_CONN_STR"
  -- runNoLoggingT, not runStdoutLoggingT: persistent logs every statement it runs, and the DDL
  -- here is four files of it. A boot that prints a thousand lines of CREATE VIEW buries the one
  -- line an operator needs, and the failure path already reports the statement that broke.
  ownerPool <- runNoLoggingT $ createPostgresqlPool (T.encodeUtf8 (T.pack ownerConnStr)) 2
  putStrLn $ "Applying palmares schema as: " <> redactConnStr ownerConnStr
  applyPalmaresSchema ownerPool
  refreshTid <- runRefreshThread ownerPool

  -- One freshness poller, seeded synchronously, feeding /ready, /status and the response headers.
  pollMs <- freshnessPollMsFromEnv
  (freshTv, attestTv, freshTid) <- startFreshnessPoll pool pollMs
  network <- expectedNetworkFromEnv
  maxLag <- readyMaxLagFromEnv
  amber <- amberLagFromEnv

  let appContext =
        QueryAppContext
          { pgPool = pool,
            freshness = freshTv,
            attestLag = attestTv,
            expectedNetwork = network,
            readyMaxLag = maxLag,
            amberLag = amber
          }
      host = "0.0.0.0"
  port <- getPortFromEnvOrDefault 8083

  let settings = setHost (fromString host :: HostPreference) $ setPort port defaultSettings
      -- Both caches, because the response headers now carry the attestation projector's state
      -- too (`CS-07`): a client scrolling an attestation page sees `X-Attest-State` on the page it is
      -- reading rather than on a second request.
      webApp = mkWebApp corsCfg ((,) <$> readTVarIO freshTv <*> readTVarIO attestTv) appContext

  putStrLn $ "Started Query API server at " <> host <> " " <> show port
  putStrLn $ "Postgres: " <> redactConnStr connStr
  putStrLn $ "Network: " <> T.unpack network <> "; ready above " <> show maxLag <> "s lag, amber above " <> show amber <> "s"
  putStrLn $ "Threads: refresh " <> show refreshTid <> ", freshness " <> show freshTid <> " (every " <> show pollMs <> "ms)"
  putStrLn $ "Swagger-UI available at : http://" <> host <> ":" <> show port <> "/swagger-ui"

  runSettings settings webApp
