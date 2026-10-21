{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module RestAPI where

import Palmares.Constants (appVersion)
import Control.Lens hiding (Context)
import Data.Swagger
import Data.Text hiding (length)
import Deriving.Aeson
import GeniusYield.Imports
import GeniusYield.Types hiding (description, title)
import InteractionAppMonad
import Network.Wai
import Network.Wai.Middleware.Servant.Options (provideOptions)
import Servant
import Servant.Swagger
import Servant.Swagger.UI
import ServiceHandlers
import ServiceRequests
import Palmares.TxBuilding.Interactions
import Palmares.WebAPI.Auth
import Palmares.WebAPI.CORS
import Palmares.WebAPI.ServiceProbe (alwaysHealthy)
import Palmares.WebAPI.ServiceProbe qualified as WebAPI.ServiceProbe
import Palmares.WebAPI.Utils (addSharedSwaggerDescriptions)

-- | Orphan 'FromHttpApiData' instance for 'GYTxId' to support URL capture.
instance FromHttpApiData GYTxId where
  parseUrlPiece t = case txIdFromHex (unpack t) of
    Just txId -> Right txId
    Nothing -> Left ("Invalid transaction ID: " <> t)

-- | Orphan 'ToParamSchema' instance for 'GYTxId' for Swagger generation.
instance ToParamSchema GYTxId where
  toParamSchema _ =
    mempty
      & type_ ?~ SwaggerString
      & Data.Swagger.format ?~ "hex"

-- Auth code moved to WebAPI.Auth

------------------------------------------------------------------------------------------------

--  Transaction Status Response

------------------------------------------------------------------------------------------------

-- | Response type for the tx-status polling endpoint.
data TxStatusResponse = TxStatusResponse
  { tsrTxId :: Text,
    tsrConfirmed :: Bool
  }
  deriving stock (Generic, Show)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "tsr", CamelToSnake]] TxStatusResponse

instance ToSchema TxStatusResponse where
  declareNamedSchema = genericDeclareNamedSchema $ fromAesonOptions $ aesonOptions @'[FieldLabelModifier '[StripPrefix "tsr", CamelToSnake]]

------------------------------------------------------------------------------------------------

--  Transactions API

------------------------------------------------------------------------------------------------

type Transactions =
  -- Build tx endpoint
  ( Summary "Build Transaction"
      :> Description "Builds Transaction for Interaction and returns it as a hex encoded CBOR"
      :> "build-tx"
      :> ReqBody '[JSON] Interaction
      :> Post '[JSON] String
  )
    :<|>
    -- Submit tx endpoint
    ( Summary "Submits Signed Transaction"
        :> Description "Submits Signed Transaction and returns the transaction id"
        :> "submit-tx"
        :> ReqBody '[JSON] AddWitAndSubmitParams
        :> Post '[JSON] GYTxId
    )
    :<|>
    -- Poll tx status endpoint
    ( Summary "Poll Transaction Status"
        :> Description "Polls the confirmation status of a submitted transaction. Returns whether the transaction has been confirmed on-chain."
        :> "tx-status"
        :> Capture "txId" GYTxId
        :> Get '[JSON] TxStatusResponse
    )

-- Health handlers moved to WebAPI.Health

handleBuildTx :: Interaction -> InteractionAppMonad String
handleBuildTx = buildInteractionApp

handleSubmitTx :: AddWitAndSubmitParams -> InteractionAppMonad GYTxId
handleSubmitTx AddWitAndSubmitParams {..} = do
  let txBody = getTxBody awasTxUnsigned
  let signedTx = makeSignedTransaction awasTxWit txBody
  submitTxApp signedTx

handleTxStatus :: GYTxId -> InteractionAppMonad TxStatusResponse
handleTxStatus txId = do
  confirmed <- pollTxConfirmation txId
  return
    TxStatusResponse
      { tsrTxId = pack (show txId),
        tsrConfirmed = confirmed
      }

transactionsServer :: ServerT Transactions InteractionAppMonad
transactionsServer = handleBuildTx :<|> handleSubmitTx :<|> handleTxStatus

------------------------------------------------------------------------------------------------

--  Service API (dedicated endpoints per action)

------------------------------------------------------------------------------------------------

type ServiceAPI =
  ( Summary "Update Profile"
      :> Description "Updates profile metadata (description, image URI). The name is immutable."
      :> "update-profile"
      :> ReqBody '[JSON] UpdateProfileRequest
      :> Post '[JSON] String
  )
    :<|> ( Summary "Issue Attestation"
             :> Description "Issues a pending attestation about a subject profile."
             :> "issue-attestation"
             :> ReqBody '[JSON] IssueAttestationRequest
             :> Post '[JSON] String
         )
    :<|> ( Summary "Accept Attestation"
             :> Description "Accepts a pending attestation; only the subject's wallet can do this."
             :> "accept-attestation"
             :> ReqBody '[JSON] AcceptAttestationRequest
             :> Post '[JSON] String
         )

serviceServer :: ServerT ServiceAPI InteractionAppMonad
serviceServer =
  handleUpdateProfile
    :<|> handleIssueAttestation
    :<|> handleAcceptAttestation

------------------------------------------------------------------------------------------------

--  Probe API

------------------------------------------------------------------------------------------------

type ProbeAPI = WebAPI.ServiceProbe.ServiceProbe Text Text

interactionProbeServer :: ServerT ProbeAPI InteractionAppMonad
interactionProbeServer = alwaysHealthy (pack appVersion) "interaction-api" :<|> checkDeployedScriptsAreReady

------------------------------------------------------------------------------------------------

--  Swagger API

------------------------------------------------------------------------------------------------

-- | Public API surface used for Swagger generation (excludes auth wrappers).
type PublicAPI = ProbeAPI :<|> Transactions :<|> ServiceAPI

proxyPublicAPI :: Proxy PublicAPI
proxyPublicAPI = Proxy

apiSwagger :: Swagger
apiSwagger =
  toSwagger proxyPublicAPI
    & info . title .~ "Palmares Interaction API"
    & info . Data.Swagger.version .~ "3.0.0"
    & info . Data.Swagger.description ?~ "This is the Palmares Interaction API — transaction building, submission, and the dedicated per-action service endpoints."
    & info . license ?~ "GPL-3.0 license"
    & host .~ Nothing
    -- Response descriptions
    & allOperations . responses . at 200 . mapped . _Inline . description .~ ("Hex-encoded unsigned transaction CBOR. Sign with your wallet and submit via /submit-tx." :: Text)
    & allOperations . responses . at 400 ?~ Inline (mempty {_responseDescription = "Validation error (invalid dates, wrong profile type, conflicting state, etc.)"})
    & allOperations . responses . at 404 ?~ Inline (mempty {_responseDescription = "Referenced entity not found (profile, attestation, or NFT)"})
    & allOperations . responses . at 503 ?~ Inline (mempty {_responseDescription = "Protocol is paused or deployed validator scripts are not yet available"})
    -- Shared type descriptions
    & addSharedSwaggerDescriptions
    -- Interaction-API-specific type descriptions
    & definitions . at "UserAddresses" . mapped . description ?~ "Wallet addresses used as inputs for transaction building. Provide all UTxO addresses from the connected wallet."

swaggerServer :: ServerT (SwaggerSchemaUI "swagger-ui" "swagger-api.json") InteractionAppMonad
swaggerServer = swaggerSchemaUIServerT apiSwagger

------------------------------------------------------------------------------------------------

--  Combined API

------------------------------------------------------------------------------------------------

-- | Adding Basic Auth to the Rest API
type PrivateTransactions =
  BasicAuth "user-realm" AuthUser :> Transactions

proxyPrivateTransactions :: Proxy PrivateTransactions
proxyPrivateTransactions = Proxy

privateTransactionsServer :: ServerT PrivateTransactions InteractionAppMonad
privateTransactionsServer = const transactionsServer

-- | Adding Basic Auth to the Service API
type PrivateServiceAPI =
  BasicAuth "user-realm" AuthUser :> ServiceAPI

privateServiceServer :: ServerT PrivateServiceAPI InteractionAppMonad
privateServiceServer = const serviceServer

-- | Adding Swagger UI on top of Private Rest API
type FullAPI =
  SwaggerSchemaUI "swagger-ui" "swagger-api.json"
    :<|> ProbeAPI
    :<|> PrivateTransactions
    :<|> PrivateServiceAPI

proxyFullAPI :: Proxy FullAPI
proxyFullAPI = Proxy

fullServer :: ServerT FullAPI InteractionAppMonad
fullServer =
  swaggerServer
    :<|> interactionProbeServer
    :<|> privateTransactionsServer
    :<|> privateServiceServer

------------------------------------------------------------------------------------------------

-- | Servant Application

------------------------------------------------------------------------------------------------

proxyServerContext :: Proxy '[BasicAuthCheck AuthUser]
proxyServerContext = Proxy

mkWebApp :: CorsConfig -> InteractionAppContext -> Application
mkWebApp corsCfg ctx =
  mkCorsMiddleware corsCfg $
    provideOptions proxyPublicAPI $
      serveWithContext proxyFullAPI ctxEntries hoistedServer
  where
    ctxEntries = authCheck (authContext ctx) :. EmptyContext
    hoistedServer = hoistServerWithContext proxyFullAPI proxyServerContext (runInteractionAppMonad ctx) fullServer
