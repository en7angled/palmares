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
import Palmares.WebAPI.Errors (palmaresErrorFormatters, refusedRequestMiddleware)
import Palmares.WebAPI.ServiceProbe (alwaysHealthy)
import Palmares.WebAPI.ServiceProbe qualified as WebAPI.ServiceProbe
import Palmares.WebAPI.Utils (addSharedSwaggerDescriptions, markNullableFields)
-- `toJSON` is not imported here: `GeniusYield.Imports` above already re-exports it, and naming it
-- again is a redundant-import warning rather than a second definition.
import Data.Aeson (Value)

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
    --
    -- 3.2.0, MINOR: `/open-dispute`'s published description was WRONG about `deposit_to` in two ways
    -- — it said the field defaults to the change address, and that "pointing it somewhere useless
    -- costs only the disputer" (`OF-02`). The default is now the address holding the opener's user
    -- token, and a named address outside `user_addresses` is a 400 instead of a build failure that
    -- read "Not enough ADA". MINOR and not MAJOR because every request body that parsed before
    -- still parses: what changed is which of them SUCCEED, and the ones that stop succeeding are
    -- the ones the chain was refusing anyway.
    --
    -- 3.3.0, MINOR: `/open-dispute` refuses a SCRIPT `deposit_to` as `DepositAddressIsScript`
    -- (`OC-06`). The refund is a datum-less output, which a script cannot spend — including at this
    -- protocol's own addresses, where it becomes sweepable dust. The chain refuses it too (`Mda`);
    -- this is the same refusal moved before the signature.
    --
    -- 3.4.0, MINOR: the document now declares 405, 406, 415, 500 and 502, which the service has
    -- always been able to return and never admitted to. Nothing about a request changed; what
    -- changed is that a client generated from this document has a branch for each of them — and that
    -- the 405 and the 406 now answer with a `{code, message}` body like every other error here,
    -- instead of the empty one servant's router wrote (see the note on `mkWebApp`).
    --
    -- 3.5.0, MINOR: `/status` publishes `oracle` — the registry's own deposit, dispute timeout,
    -- minimum UTxO, fees and admin/arbiter credentials. Three screens could not be built without
    -- it: a client cannot ask for a signature on a deposit it cannot name, cannot show a dispute's
    -- deadline, and cannot say who decides it. This service is the only one able to publish them,
    -- because query-api carries no Cardano provider and the db-sync behind it is indexed without
    -- UTxOs. Also additive: every nullable field in this document now carries `x-nullable`, so a
    -- generated client stops typing an optional field as non-null.
    & info . Data.Swagger.version .~ "3.5.0"
    & info . Data.Swagger.description ?~ "This is the Palmares Interaction API — transaction building, submission, and the dedicated per-action service endpoints."
    -- Apache-2.0, which is what `palmares.cabal`, `LICENSE` and the README say. This published
    -- "GPL-3.0 license" for as long as the document has existed — inherited, never looked at, and
    -- regenerated into the committed file on every boot. `scripts/check_swagger.sh` asserted the
    -- licence on the query document only, which is why nothing caught it.
    & info . license ?~ "Apache-2.0"
    & host .~ Nothing
    -- Response descriptions
    -- One description for every operation, so it has to be true of every operation: /health, /ready,
    -- /status and /tx-status return their own JSON and always did, while the blanket text said
    -- "hex-encoded unsigned transaction CBOR" about all of them.
    & allOperations . responses . at 200 . mapped . _Inline . description .~ ("Success. The write routes return the hex-encoded unsigned transaction CBOR — sign it with your wallet and submit it via /submit-tx; the probe, status and tx-status routes return the JSON object their schema names." :: Text)
    & allOperations . responses . at 400 ?~ Inline (mempty {_responseDescription = "Validation error (invalid dates, wrong profile type, conflicting state, etc.)"})
    & allOperations . responses . at 404 ?~ Inline (mempty {_responseDescription = "Referenced entity not found (profile, attestation, or NFT), or no route matches the path"})
    & allOperations . responses . at 503 ?~ Inline (mempty {_responseDescription = "Protocol is paused or deployed validator scripts are not yet available"})
    -- The five statuses the service could always return and the document never admitted to. A
    -- generated client branches on what it is given, so an undeclared status is a branch that does
    -- not exist — and 502 was the one that mattered: it is what a submission the node rejected
    -- answers, which is NOT the caller's fault and is the one error worth retrying.
    --
    -- 405, 406 and 415 are the ROUTER's and not a handler's, which is why they are declared on every
    -- operation rather than on any one of them: they are a property of asking for a path the wrong
    -- way, and every path can be asked for the wrong way. The first two carry the same
    -- `{code, message}` body as everything else here — `method_not_allowed`, `not_acceptable`, from
    -- `refusedRequestMiddleware` — which they did not before this version. The 415 is declared with
    -- no code named, because it is the one refusal still answering with an empty body; see the note
    -- on `mkWebApp`.
    --
    -- 401 is deliberately absent: this document is generated from `PublicAPI`, which excludes the
    -- `BasicAuth` combinator on purpose, so declaring 401 on /health and /ready would describe a
    -- refusal those routes do not make.
    & allOperations . responses . at 405 ?~ Inline (mempty {_responseDescription = "Wrong HTTP method for this path. Code: method_not_allowed. Every write route is a POST; /health, /ready, /status and /tx-status are GETs."})
    & allOperations . responses . at 406 ?~ Inline (mempty {_responseDescription = "The Accept header asked for a media type this service does not produce; it serves application/json only. Code: not_acceptable."})
    & allOperations . responses . at 415 ?~ Inline (mempty {_responseDescription = "The request body was not sent as application/json. Set Content-Type: application/json."})
    & allOperations . responses . at 500 ?~ Inline (mempty {_responseDescription = "A bug here, never a condition the request can fix: an unclassified failure (InternalError, or internal_error from the last-resort handler), or a datum this protocol wrote and cannot now parse (OracleDatumInvalid, DatumParseError)."})
    & allOperations . responses . at 502 ?~ Inline (mempty {_responseDescription = "The chain provider could not be reached, or the node rejected the submission. Code: ProviderError. The request was well formed and may be worth retrying."})
    -- Shared type descriptions
    & addSharedSwaggerDescriptions
    -- Interaction-API-specific type descriptions
    & definitions . at "UserAddresses" . mapped . description ?~ "Wallet addresses used as inputs for transaction building. Provide all UTxO addresses from the connected wallet."

-- | The document as it is SERVED and as it is WRITTEN — the same bytes, which is the point of there
-- being one value.
--
-- swagger2 has no extension field on @Schema@, so @x-nullable@ cannot come from a 'ToSchema'
-- instance or from 'SchemaOptions': it is added by a pass over the encoded document, keyed on the
-- one fact that is already true of it — @genericDeclareNamedSchema@ omits a property from
-- @required@ exactly when its type is @Maybe a@. Without the key, a generated TypeScript client
-- types every optional field non-null and throws on the first null the API returns, which on this
-- service is most of @\/status@.
apiSwaggerDoc :: Value
apiSwaggerDoc = markNullableFields (toJSON apiSwagger)

swaggerServer :: ServerT (SwaggerSchemaUI "swagger-ui" "swagger-api.json") InteractionAppMonad
swaggerServer = swaggerSchemaUIServerT apiSwaggerDoc

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

-- 'ErrorFormatters' is in the context too, and that is the fix: without it servant answers a
-- refused request with `text/plain` and no `code`, which on a write API is the most common error a
-- client sees. Both entries, in the same order as `ctxEntries` below.
proxyServerContext :: Proxy '[BasicAuthCheck AuthUser, ErrorFormatters]
proxyServerContext = Proxy

-- 'refusedRequestMiddleware' is the 405\/406 half, and it is the LIBRARY's, not a copy.
--
-- MEASURED against this service before it was installed: @GET \/expire-dispute@ answered 405 and
-- @GET \/status@ with @Accept: text\/csv@ answered 406, both with no content type and a zero-byte
-- body — so a browser client calling @res.json()@ on a failure path threw a parse error instead of
-- reading a code. The cause is that these two are decided by servant's ROUTER, before any handler
-- and before 'palmaresErrorFormatters': @ErrorFormatters@ has four hooks (a URL piece, a header, a
-- body, and not-found) and none of them is about a method or an @Accept@ header.
--
-- Both services had the defect identically, which is why the fix belongs where the error vocabulary
-- already lives rather than in this module. The same middleware now answers
-- @{\"code\":\"method_not_allowed\"…}@ and @{\"code\":\"not_acceptable\"…}@ on both.
--
-- It sits INSIDE the CORS middleware and OUTSIDE 'provideOptions', for two reasons that are each
-- about what a layer answers. CORS outside, so a rewritten refusal still carries its
-- @Access-Control-Allow-*@ headers — a browser that cannot read a 405's body learns nothing from it.
-- 'provideOptions' inside, so a CORS preflight is answered 200 by that middleware and never reaches
-- a layer that looks at bodiless responses.
--
-- __One refusal is still bodiless, deliberately left to its owner:__ a 415 (a POST whose
-- @Content-Type@ is not @application\/json@) and an unrouted 404 come out of the same routing layer
-- with the same empty body. Both are two rows in 'refusedRequestMiddleware'\''s own table, which is
-- in @webapi-lib@; adding them here would be the second copy this comment exists to avoid. The 415
-- IS declared in the document below, because the service does return it.
mkWebApp :: CorsConfig -> InteractionAppContext -> Application
mkWebApp corsCfg ctx =
  mkCorsMiddleware corsCfg $
    refusedRequestMiddleware $
      provideOptions proxyPublicAPI $
        serveWithContext proxyFullAPI ctxEntries hoistedServer
  where
    ctxEntries = authCheck (authContext ctx) :. palmaresErrorFormatters :. EmptyContext
    hoistedServer = hoistServerWithContext proxyFullAPI proxyServerContext (runInteractionAppMonad ctx) fullServer
