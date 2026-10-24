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
import RestAPI (apiSwaggerDoc, mkWebApp)
import System.Environment (getArgs)
import System.Exit (die, exitSuccess)
import Palmares.TxBuilding.Context
import Palmares.Utils (decodeConfigEnvOrFile)
import Palmares.WebAPI.Auth (getBasicAuthFromEnv)
import Palmares.WebAPI.CORS (getCorsConfigFromEnv)
import Palmares.WebAPI.Errors (internalErrorResponse)
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
-- 'apiSwaggerDoc' is a pure value derived from the served API type.
writeSwagger :: IO ()
writeSwagger = do
  BL8.writeFile swaggerPath (encodePretty apiSwaggerDoc)
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

    -- 'setOnExceptionResponse' is the last resort, and it is why this document can declare a 500 and
    -- mean it. Warp's own default is `text/plain` with the words "Something went wrong", produced
    -- OUTSIDE the middleware stack — when the application throws, the continuation
    -- 'refusedRequestMiddleware' wraps is never called, so no WAI layer can reshape it. Almost every
    -- 500 on this service already carries `{code, message}`, because 'runWithTxErrorHandling' catches
    -- 'SomeException' and classifies it; this covers the rest, so "every non-2xx body on this API is
    -- JSON with a code" has no exception left for a client to special-case.
    let settings =
          setOnExceptionResponse (const internalErrorResponse) $
            setHost (fromString host :: HostPreference) $
              setPort port defaultSettings
    let webApp = mkWebApp corsCfg appContext

    putStrLn $ "Started Interaction API server at " <> host <> " " <> show port
    putStrLn $ "Atlas config: " <> show atlasConfig
    putStrLn $ "Deployed validators config: " <> show deployedScriptsContext
    putStrLn $ "Swagger-UI available at : http://" <> host <> ":" <> show port <> "/swagger-ui"

    runSettings settings webApp
