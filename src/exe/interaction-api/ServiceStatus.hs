{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @GET \/status@: the facts behind \"can this service build a transaction right now\".
--
-- __Why it exists.__ @\/health@ answers 'Palmares.WebAPI.ServiceProbe.alwaysHealthy' — it touches
-- nothing, which is correct for a liveness probe and useless to an operator: it reports @healthy@
-- with a dead provider and with reference scripts that do not resolve. @\/ready@ answers the one
-- question a load balancer needs, as a status code. Neither says WHICH provider, WHICH network, or
-- whether the protocol is paused, and those are the three answers that explain a service refusing
-- every write.
--
-- __It always answers 200.__ A status route that fails when the thing it reports on is broken tells
-- you nothing, which is the defect it was written against. @\/ready@ is the route that 503s.
--
-- __It is public, beside the probes.__ Everything here is either an on-chain fact or the provider's
-- family name; nothing is a secret and nothing needs the operator's credentials. It does cost two
-- provider round trips per request, which @\/ready@ already costs today.
module ServiceStatus (InteractionStatusResponse (..), getStatus) where

import Control.Exception (SomeException, fromException, try)
import Control.Lens ((&), (?~))
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Data.Swagger (ToSchema (..), description, genericDeclareNamedSchema)
import Data.Swagger qualified as Swagger
import Data.Text (Text, pack)
import Data.Typeable (cast)
import Deriving.Aeson
import GeniusYield.GYConfig (GYCoreConfig (..), GYCoreProviderInfo (..))
import GeniusYield.TxBuilder (GYTxQueryMonadIO)
import GeniusYield.TxBuilder.Errors (GYTxMonadException (..))
import GeniusYield.Types (GYNetworkId (..))
import InteractionAppMonad (InteractionAppContext (..), InteractionAppMonad)
import Palmares.Constants (appVersion)
import Palmares.TxBuilding.Context (DeployedScriptsContext, ProviderCtx (..), TxBuildingContext (..), runQuery)
import Palmares.TxBuilding.Exceptions (TxBuildingException (ProtocolPaused))
import Palmares.TxBuilding.Operations (getOracleRefInputSkeleton, verifyDeployedScriptsAreReady)
import Palmares.Utils (mkStripPrefixSchemaOptions)

-------------------------------------------------------------------------------

-- * The response

-------------------------------------------------------------------------------

-- | What an operator needs in order to explain a refused write.
data InteractionStatusResponse = InteractionStatusResponse
  { -- | The provider FAMILY, never its configuration: a hosted provider's key is @Confidential@ and hidden
    -- even from @show@, but a node socket path and a Kupo URL are not, and an unauthenticated route
    -- has no business publishing internal addresses.
    statusProvider :: Text,
    statusNetwork :: Text,
    -- | Do all five reference scripts resolve on chain. @false@ also covers \"the provider could not
    -- be reached to find out\", because for this flag the two have the same consequence: nothing can
    -- be built. Which of the two it is shows in @oracle_paused@ being @null@.
    statusDeployedScripts :: Bool,
    -- | The oracle's pause flag — @null@ when the oracle could not be read at all, which is a
    -- different fact from @false@ and must not be reported as it.
    statusOraclePaused :: Maybe Bool,
    statusVersion :: Text
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "status", CamelToSnake]] InteractionStatusResponse

instance ToSchema InteractionStatusResponse where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "status") proxy
    return $
      s
        & Swagger.schema . description
          ?~ "Which provider and network this service is configured against, whether its reference \
             \scripts resolve, and whether the protocol is paused. Always 200: /ready is the route \
             \that fails."

-------------------------------------------------------------------------------

-- * The handler

-------------------------------------------------------------------------------

-- | Two chain reads, each allowed to fail without failing the response.
getStatus :: InteractionAppMonad InteractionStatusResponse
getStatus = do
  InteractionAppContext {..} <- ask
  let cfg = ctxCoreCfg (providerCtx txBuildingContext)
  scripts <- liftIO (probe txBuildingContext verifyDeployedScriptsAreReady)
  oracle <- liftIO (probe txBuildingContext (void getOracleRefInputSkeleton))
  return
    InteractionStatusResponse
      { statusProvider = providerFamily (cfgCoreProvider cfg),
        statusNetwork = networkName (cfgNetworkId cfg),
        statusDeployedScripts = either (const False) id scripts,
        statusOraclePaused = pausedFrom oracle,
        statusVersion = pack appVersion
      }

-- | Run a deployed-scripts query, reporting any failure — a refusal, a dead provider, a timeout —
-- as the failure itself rather than propagating it.
probe :: TxBuildingContext -> ReaderT DeployedScriptsContext GYTxQueryMonadIO a -> IO (Either SomeException a)
probe ctx query = try (runQuery (providerCtx ctx) (runReaderT query (deployedScriptsCtx ctx)))

-- | The pause flag, read off the gate the WRITE path uses rather than off the datum directly.
--
-- 'getOracleRefInputSkeleton' is what every write calls, and it throws 'ProtocolPaused' when the
-- oracle says so — so this answers \"would a write be refused as paused\", which is the question,
-- and it cannot disagree with the production check because it IS the production check. Any other
-- failure is 'Nothing': the oracle was not read, and a @false@ there would be a claim we cannot make.
pausedFrom :: Either SomeException () -> Maybe Bool
pausedFrom (Right ()) = Just False
pausedFrom (Left e)
  | Just (GYApplicationException appE) <- fromException e,
    Just ProtocolPaused <- cast appE =
      Just True
  | otherwise = Nothing

-- | The provider family, with no configuration in it. Exhaustive on purpose: a new Atlas provider
-- must be named here rather than silently reported as something it is not.
providerFamily :: GYCoreProviderInfo -> Text
providerFamily GYNodeKupo {} = "node-kupo"
providerFamily GYOgmiosKupo {} = "ogmios-kupo"
providerFamily GYMaestro {} = "maestro"
providerFamily GYBlockfrost {} = "blockfrost"

-- | db-sync's own spelling, which is what query-api's @\/status@ reports for @network@ — the two
-- services describe the same deployment and a client should not have to translate between them.
networkName :: GYNetworkId -> Text
networkName GYMainnet = "mainnet"
networkName GYTestnetPreprod = "preprod"
networkName GYTestnetPreview = "preview"
networkName GYTestnetLegacy = "legacy"
networkName (GYPrivnet _) = "privnet"
