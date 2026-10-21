module Main where

import Palmares.Constants
  ( defaultAtlasCoreConfig,
    defaultTxBuildingContextFile,
  )
import Data.Aeson.Encode.Pretty
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.String (IsString (..))
import GeniusYield.GYConfig
import GeniusYield.Types
import InteractionAppMonad (InteractionAppContext (..))
import Network.Wai.Handler.Warp
import RestAPI (apiSwagger, mkWebApp)
import System.Environment (getArgs)
import System.Exit (die, exitSuccess)
import Palmares.TxBuilding.Context
import Palmares.Utils (decodeConfigEnvOrFile)
import Palmares.WebAPI.Auth (getBasicAuthFromEnv)
import Palmares.WebAPI.CORS (getCorsConfigFromEnv)
import Palmares.WebAPI.Utils (getPortFromEnvOrDefault)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- | The committed document this service's API type produces.
--
-- ONE producer, the same shape query-api already uses. It used to be written on every boot, which
-- meant the only way to obtain it was to start a server — and starting THIS server needs an Atlas
-- provider config, so CI never obtained it at all. The result was that the interaction API's
-- published request contract had no drift gate and was not even in the repository, while the query
-- API's had both. The @kind@/@claimed_period@ work found a wrong enum spelling in this document by
-- generating it by hand, which is the argument for the gate rather than a theory about it.
swaggerPath :: FilePath
swaggerPath = "docs/generated/swagger/interaction-swagger-api.json"

-- | @--write-swagger-only@: write the document and exit.
--
-- Touches nothing else — no Atlas config, no deployed-validators config, no port — because
-- 'apiSwagger' is a pure value derived from the served API type.
writeSwagger :: IO ()
writeSwagger = do
  BL8.writeFile swaggerPath (encodePretty apiSwagger)
  putStrLn ("Wrote " <> swaggerPath)

main :: IO ()
main = do
  -- Line-buffer stdout: GHC block-buffers it when it is not a TTY, which is the case under
  -- Docker and Kubernetes, so boot lines would sit in a buffer while the service already serves.
  -- Measured on query-api, fixed in all three servers at once.
  hSetBuffering stdout LineBuffering

  args <- getArgs
  case args of
    ["--write-swagger-only"] -> writeSwagger >> exitSuccess
    _ -> serve

serve :: IO ()
serve = do
  atlasConfig <- maybe (die "Atlas configuration failed") return =<< decodeConfigEnvOrFile "ATLAS_CORE_CONFIG" defaultAtlasCoreConfig
  deployedScriptsContext <- maybe (die "Deployed validators configuration failed") return =<< decodeConfigEnvOrFile "DEPLOYED_VALIDATORS_CONFIG" defaultTxBuildingContextFile

  withCfgProviders atlasConfig (read @GYLogNamespace "Palmares") $ \providers -> do
    let providersContext = ProviderCtx atlasConfig providers
    let txBuildingContext = TxBuildingContext deployedScriptsContext providersContext
    authContext <- getBasicAuthFromEnv
    corsCfg <- getCorsConfigFromEnv
    let appContext = InteractionAppContext authContext txBuildingContext

    let host = "0.0.0.0"
    port <- getPortFromEnvOrDefault 8082

    let settings = setHost (fromString host :: HostPreference) $ setPort port defaultSettings
    let webApp = mkWebApp corsCfg appContext

    putStrLn $ "Started Interaction API server at " <> host <> " " <> show port
    putStrLn $ "Atlas config: " <> show atlasConfig
    putStrLn $ "Deployed validators config: " <> show deployedScriptsContext
    putStrLn $ "Swagger-UI available at : http://" <> host <> ":" <> show port <> "/swagger-ui"

    runSettings settings webApp
