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
import ServiceStatus (InteractionStatusResponse, getStatus)
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
  ( Summary "Claim Profile"
      :> Description "Mints a profile. The profile claims no credential; bind one with POST /claim-credential, which is a separate record and a separate transaction."
      :> "claim-profile"
      :> ReqBody '[JSON] ClaimProfileRequest
      :> Post '[JSON] String
  )
    :<|> ( Summary "Update Profile"
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
    :<|> ( Summary "Open Dispute"
             :> Description "Contests an attestation, locking the deposit the oracle currently requires."
             :> "open-dispute"
             :> ReqBody '[JSON] OpenDisputeRequest
             :> Post '[JSON] String
         )
    :<|> ( Summary "Resolve Dispute"
             :> Description "Settles a dispute. The oracle validator requires the admin's signature, so the unsigned transaction this returns is for the admin to sign — which is why the route exists at all, while no admin action is accepted over HTTP."
             :> "resolve-dispute"
             :> ReqBody '[JSON] ResolveDisputeRequest
             :> Post '[JSON] String
         )
    :<|> ( Summary "Expire Dispute"
             :> Description "Closes an undecided dispute whose deadline has passed. Needs no authority at all — that is the point, since an exit the oracle admin can gate is not an exit — and records `expired`, which is not a finding against either party. The deposit returns to the address the opener named."
             :> "expire-dispute"
             :> ReqBody '[JSON] ExpireDisputeRequest
             :> Post '[JSON] String
         )
    :<|> ( Summary "Claim Credential"
             :> Description "Binds a profile to a Cardano credential as an append-only record — ADR 0003. Needs BOTH parties: the transaction spends the profile's user token and must also be authorised by the credential. A second call after /claim-profile, which no longer claims anything."
             :> "claim-credential"
             :> ReqBody '[JSON] ClaimCredentialRequest
             :> Post '[JSON] String
         )
    :<|> ( Summary "Withdraw Credential"
             :> Description "Ends a profile's binding to a credential. Authorised by the CREDENTIAL alone — not by the profile's owner, who may be exactly the party that claimed a credential they do not control. Nothing is deleted: the claim stays on chain and this record is appended beside it."
             :> "withdraw-credential"
             :> ReqBody '[JSON] WithdrawCredentialRequest
             :> Post '[JSON] String
         )

serviceServer :: ServerT ServiceAPI InteractionAppMonad
serviceServer =
  handleClaimProfile
    :<|> handleUpdateProfile
    :<|> handleIssueAttestation
    :<|> handleAcceptAttestation
    :<|> handleOpenDispute
    :<|> handleResolveDispute
    :<|> handleExpireDispute
    :<|> handleClaimCredential
    :<|> handleWithdrawCredential

------------------------------------------------------------------------------------------------

--  Probe API

------------------------------------------------------------------------------------------------

type ProbeAPI = WebAPI.ServiceProbe.ServiceProbe Text Text

interactionProbeServer :: ServerT ProbeAPI InteractionAppMonad
interactionProbeServer = alwaysHealthy (pack appVersion) "interaction-api" :<|> checkDeployedScriptsAreReady

------------------------------------------------------------------------------------------------

--  Status API

------------------------------------------------------------------------------------------------

-- | Public, beside the probes, and for the reason 'ServiceStatus' documents: @\/health@ cannot
-- answer any of this and @\/ready@ answers only with a status code.
type StatusAPI =
  Summary "Service Status"
    :> Description "The provider family, the network, whether the five reference scripts resolve, and the oracle's pause flag. Always 200 — /ready is the route that fails."
    :> "status"
    :> Get '[JSON] InteractionStatusResponse

statusServer :: ServerT StatusAPI InteractionAppMonad
statusServer = getStatus

------------------------------------------------------------------------------------------------

--  Swagger API

------------------------------------------------------------------------------------------------

-- | Public API surface used for Swagger generation (excludes auth wrappers).
type PublicAPI = ProbeAPI :<|> StatusAPI :<|> Transactions :<|> ServiceAPI

proxyPublicAPI :: Proxy PublicAPI
proxyPublicAPI = Proxy

apiSwagger :: Swagger
apiSwagger =
  toSwagger proxyPublicAPI
    & info . title .~ "Palmares Interaction API"
    -- 3.1.0, MINOR: `DisputeActionType` gained `ExpireDisputeAction` and `DisputeVerdict` gained
    -- `expired` (D-A). Both additive: every request body that parsed before still parses.
    & info . Data.Swagger.version .~ "3.1.0"
    & info . Data.Swagger.description ?~ "This is the Palmares Interaction API — transaction building, submission, and the dedicated per-action service endpoints."
    & info . license ?~ "GPL-3.0 license"
    & host .~ Nothing
    -- Response descriptions
    -- One description for every operation, so it has to be true of every operation: /health, /ready,
    -- /status and /tx-status return their own JSON and always did, while the blanket text said
    -- "hex-encoded unsigned transaction CBOR" about all of them.
    & allOperations . responses . at 200 . mapped . _Inline . description .~ ("Success. The write routes return the hex-encoded unsigned transaction CBOR — sign it with your wallet and submit it via /submit-tx; the probe, status and tx-status routes return the JSON object their schema names." :: Text)
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
    :<|> StatusAPI
    :<|> PrivateTransactions
    :<|> PrivateServiceAPI

proxyFullAPI :: Proxy FullAPI
proxyFullAPI = Proxy

fullServer :: ServerT FullAPI InteractionAppMonad
fullServer =
  swaggerServer
    :<|> interactionProbeServer
    :<|> statusServer
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
