module Main where

import Palmares.Constants (defaultAtlasCoreConfig, defaultTxBuildingContextFile)
import Control.Monad.Logger (runStdoutLoggingT)
import Data.Aeson.Encode.Pretty
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Maybe
import Data.String (IsString (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Database.Persist.Postgresql (createPostgresqlPool)
import GeniusYield.GYConfig
import GeniusYield.Types
import Network.Wai.Handler.Warp
import Query.Refresh (runRefreshThread)
import Query.Views (applyPalmaresSchema)
import QueryAppMonad (QueryAppContext (..))
import RestAPI (apiSwagger, mkWebApp)
import System.Environment
import System.Exit (die)
import Palmares.TxBuilding.Context
import Palmares.Utils (decodeConfigEnvOrFile)
import Palmares.WebAPI.Auth (getBasicAuthFromEnv)
import Palmares.WebAPI.CORS (getCorsConfigFromEnv)
import Palmares.WebAPI.Utils (getPortFromEnvOrDefault)

defaultConnStr :: String
defaultConnStr = "host=postgres user=postgres password=postgres dbname=chainsync port=5432"

-- | Show only the host and dbname fields of a Postgres DSN, hiding the password.
redactConnStr :: String -> String
redactConnStr s =
  unwords [kv | kv <- words s, let k = takeWhile (/= '=') kv, k `elem` ["host", "dbname", "port"]]

main :: IO ()
main = do
  putStrLn "Writing Swagger file ..."
  BL8.writeFile "docs/generated/swagger/query-swagger-api.json" (encodePretty apiSwagger)

  atlasConfig <- maybe (die "Atlas configuration failed") return =<< decodeConfigEnvOrFile "ATLAS_CORE_CONFIG" defaultAtlasCoreConfig

  withCfgProviders atlasConfig (read @GYLogNamespace "Palmares") $ \providers -> do
    let providerContext = ProviderCtx atlasConfig providers
    authContext <- getBasicAuthFromEnv
    corsCfg <- getCorsConfigFromEnv
    connStr <- fromMaybe defaultConnStr <$> lookupEnv "PG_CONN_STR"
    pool <- runStdoutLoggingT $ createPostgresqlPool (T.encodeUtf8 (T.pack connStr)) 10

    -- The `palmares` schema is applied at BOOT, by this process, in one transaction, and the
    -- process dies if it fails (Query.Views). Every object in it is a view over db-sync, so
    -- there is no state to migrate: 000_schema.sql drops and re-creates the schema and the rest
    -- rebuild its contents, which makes the bootstrap idempotent and makes a db-sync upgrade
    -- that CASCADE-dropped our views self-healing on restart.
    --
    -- A SECOND pool, on its own DSN, because applying DDL and refreshing a matview need owner
    -- rights while every request should be served by a read-only role. PALMARES_PG_OWNER_CONN_STR
    -- defaults to PG_CONN_STR so a single-role deployment works unchanged; setting it is what
    -- separates the two once the roles exist.
    ownerConnStr <- fromMaybe connStr <$> lookupEnv "PALMARES_PG_OWNER_CONN_STR"
    ownerPool <- runStdoutLoggingT $ createPostgresqlPool (T.encodeUtf8 (T.pack ownerConnStr)) 2
    putStrLn $ "Applying palmares schema as: " <> redactConnStr ownerConnStr
    applyPalmaresSchema ownerPool
    refreshTid <- runRefreshThread ownerPool
    mDeployedCtx <- decodeConfigEnvOrFile "DEPLOYED_VALIDATORS_CONFIG" defaultTxBuildingContextFile
    let appContext = QueryAppContext authContext providerContext pool mDeployedCtx
    let host = "0.0.0.0"
    port <- getPortFromEnvOrDefault 8083

    let settings = setHost (fromString host :: HostPreference) $ setPort port defaultSettings
    let webApp = mkWebApp corsCfg appContext

    putStrLn $ "Started Query API server at " <> host <> " " <> show port
    putStrLn $ "Atlas config: " <> show atlasConfig
    putStrLn $ "Postgres: " <> redactConnStr connStr
    putStrLn $ "palmares.drep_metrics refresh thread: " <> show refreshTid
    putStrLn $ "Swagger-UI available at : http://" <> host <> ":" <> show port <> "/swagger-ui"

    runSettings settings webApp
