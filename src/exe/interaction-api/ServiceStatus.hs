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
-- family name; nothing is a secret and nothing needs the operator's credentials. It costs THREE
-- provider round trips per request — the third reads the oracle datum, which is what @oracle@
-- publishes and which this service is the only one able to read: query-api carries no Cardano
-- provider at all, by a documented boot contract of \"nothing but a Postgres DSN\", and the db-sync
-- behind it is indexed without UTxOs, so the oracle UTxO is not in that database either.
--
-- @oracle@ and @oracle_paused@ come from two separate reads on purpose. @opPaused@ lives in the very
-- datum @oracle@ returns, so one read could serve both — but @oracle_paused@ is read off
-- 'getOracleRefInputSkeleton', the gate every WRITE goes through, precisely so it cannot disagree
-- with the production check. Deriving it from the datum would trade that guarantee for a round trip.
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
import Palmares.DomainTypes.Transfer.Types (OracleParamsResponse)
import Palmares.TxBuilding.Context (DeployedScriptsContext, ProviderCtx (..), TxBuildingContext (..), runQuery)
import Palmares.TxBuilding.Conversions (oracleParamsResponse)
import Palmares.TxBuilding.Exceptions (TxBuildingException (ProtocolPaused))
import Palmares.TxBuilding.Lookups (queryOracleParams)
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
    -- | Do all five reference scripts resolve on chain __and carry the script this build expects__ —
    -- compiled hash = configured hash = the hash of the script actually at that @TxOutRef@ (@OF-08@).
    -- @false@ also covers \"the provider could not be reached to find out\", because for this flag the
    -- two have the same consequence: nothing can be built. Which of the two it is shows in
    -- @oracle_paused@ being @null@.
    statusDeployedScripts :: Bool,
    -- | The oracle's pause flag — @null@ when the oracle could not be read at all, which is a
    -- different fact from @false@ and must not be reported as it.
    statusOraclePaused :: Maybe Bool,
    -- | The oracle's mutable parameters — the dispute deposit and timeout, the minimum UTxO, the
    -- admin and arbiter credentials, and the two fees. @null@ when the oracle could not be read,
    -- the same distinction @oracle_paused@ makes and for the same reason.
    --
    -- This is the only place the registry's own parameters are published. @\/status@ on query-api
    -- carries @epoch_params@, which is the LEDGER's protocol parameters and a different thing
    -- entirely; a client that reads a deposit from there is reading Cardano's numbers, not this
    -- protocol's.
    statusOracle :: Maybe OracleParamsResponse,
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
             \scripts resolve, whether the protocol is paused, and the oracle's mutable parameters. \
             \`oracle` is the ONLY published source of the registry's own deposit, dispute timeout, \
             \minimum UTxO, fees and admin/arbiter credentials — query-api's `epoch_params` is the \
             \LEDGER's protocol parameters and a different thing. Always 200: /ready is the route \
             \that fails."

-------------------------------------------------------------------------------

-- * The handler

-------------------------------------------------------------------------------

-- | Three chain reads, each allowed to fail without failing the response.
getStatus :: InteractionAppMonad InteractionStatusResponse
getStatus = do
  InteractionAppContext {..} <- ask
  let cfg = ctxCoreCfg (providerCtx txBuildingContext)
  scripts <- liftIO (probe txBuildingContext verifyDeployedScriptsAreReady)
  oracle <- liftIO (probe txBuildingContext (void getOracleRefInputSkeleton))
  params <- liftIO (probe txBuildingContext (paramsOf <$> queryOracleParams))
  return
    InteractionStatusResponse
      { statusProvider = providerFamily (cfgCoreProvider cfg),
        statusNetwork = networkName (cfgNetworkId cfg),
        statusDeployedScripts = either (const False) id scripts,
        statusOraclePaused = pausedFrom oracle,
        statusOracle = either (const Nothing) (Just . oracleParamsResponse) params,
        statusVersion = pack appVersion
      }
  where
    paramsOf (p, _ref, _value) = p

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
