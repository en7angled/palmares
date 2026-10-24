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

-- | Build tx endpoint.
type BuildTxRoute =
  Summary "Build Transaction"
    :> Description "Builds Transaction for Interaction and returns it as a hex encoded CBOR"
    :> "build-tx"
    :> ReqBody '[JSON] Interaction
    :> Post '[JSON] String

-- | Submit tx endpoint.
type SubmitTxRoute =
  Summary "Submits Signed Transaction"
    :> Description "Submits Signed Transaction and returns the transaction id"
    :> "submit-tx"
    :> ReqBody '[JSON] AddWitAndSubmitParams
    :> Post '[JSON] GYTxId

-- | Poll tx status endpoint — __the only authenticated route with no @ReqBody@__, which is why it
-- has a name of its own: it is the exception that makes 'requestBodyOperations' necessary, because
-- it shares the auth boundary with the other eleven and cannot answer a 415 like them.
type TxStatusRoute =
  Summary "Poll Transaction Status"
    :> Description "Polls the confirmation status of a submitted transaction. Returns whether the transaction has been confirmed on-chain."
    :> "tx-status"
    :> Capture "txId" GYTxId
    :> Get '[JSON] TxStatusResponse

-- | The three routes of the transaction API.
--
-- __The three halves are named rather than inlined so that a SUBSET of them can be spoken about__ —
-- 'requestBodyOperations' needs \"build-tx and submit-tx but not tx-status\", and a type is the only
-- way to say that without a hand-kept list of paths. Spelled right-associatively, exactly as the
-- inline version parsed (@a ':<|>' b ':<|>' c@ is @a ':<|>' (b ':<|>' c)@), so 'ServerT' has the same
-- shape and 'transactionsServer' below is unchanged.
type Transactions = BuildTxRoute :<|> SubmitTxRoute :<|> TxStatusRoute

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

-- | The twelve routes behind @BasicAuth@, as a traversal into the generated document.
--
-- __This exists because @allOperations@ is the wrong tool for the 401 and the 403.__ Those two are
-- a property of the AUTH BOUNDARY, not of asking for a path the wrong way: @\/health@, @\/ready@ and
-- @\/status@ are outside 'PrivateTransactions' and 'PrivateServiceAPI' and cannot answer either, so
-- declaring them on every operation would describe a refusal three routes do not make — which is
-- the reason 401 was left out of this document altogether, and leaving a status every client meets
-- first undeclared turned out to be the worse of the two errors.
--
-- @Transactions :<|> ServiceAPI@ is exactly the authenticated set, and 'subOperations' resolves it
-- against 'PublicAPI' by matching path and method, so the split is derived from the API type rather
-- than from a hand-kept list of paths. The eleven POSTs and @GET \/tx-status\/{txId}@ are the twelve.
authenticatedOperations :: Traversal' Swagger Operation
authenticatedOperations = subOperations (Proxy :: Proxy (Transactions :<|> ServiceAPI)) proxyPublicAPI

-- | The eleven routes that accept a request body, as a traversal into the generated document.
--
-- A 415 comes from @ReqBody@'s own content-type check, so it is a property of HAVING a body and of
-- nothing else. Declared on 'allOperations' it landed on four routes that cannot produce it —
-- @\/health@, @\/ready@, @\/status@ and @GET \/tx-status\/{txId}@ — which is the same defect as
-- publishing @invalid_asset_class@ with no site: a branch a generated client writes and never
-- exercises.
--
-- __Derived from the API type, not from a list of paths__, which is the whole reason 'BuildTxRoute'
-- and 'SubmitTxRoute' have names: a path list is the thing that goes stale silently, and this one
-- would have gone stale on the next route added. @\/tx-status@ is the route that makes this traversal
-- different from 'authenticatedOperations' — authenticated, so it declares 401 and 403, and
-- body-less, so it does not declare 415.
--
-- Every one of the eleven is a @POST@ and every @POST@ here has a body, so a traversal over POSTs
-- would select the same set today. It is not written that way on purpose: that coincidence is not a
-- fact about @ReqBody@, and the first body-less POST would quietly re-open the defect.
requestBodyOperations :: Traversal' Swagger Operation
requestBodyOperations =
  subOperations (Proxy :: Proxy (BuildTxRoute :<|> SubmitTxRoute :<|> ServiceAPI)) proxyPublicAPI

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
    -- 3.6.0, MINOR: every refusal this service makes now answers `{code, message}`, and the two
    -- statuses it never admitted to are declared.
    --
    --   * The unrouted 404 answers `route_not_found` instead of an empty body with no content type.
    --     The STATUS was already declared on every operation and the description already said "or no
    --     route matches the path"; what it could not do was name a code, because there was none.
    --   * The 415 answers `unsupported_media_type`. Declared since 3.4.0, bodiless until now — and
    --     NARROWED to the eleven routes that have a request body. It was on all fifteen, four of
    --     which cannot produce it (`/health`, `/ready`, `/status`, `GET /tx-status/{txId}`). A
    --     REMOVED declaration is the one non-additive edit in this version, and it is additive in
    --     the direction that matters: no client loses a response it could receive, four of them stop
    --     carrying a branch for one they could not.
    --   * 401 and 403 are DECLARED, on the twelve authenticated routes only, and answer
    --     `unauthenticated` and `credentials_rejected`. Both were reachable from the first request
    --     any client makes and appeared nowhere in this document; both answered zero bytes with no
    --     content type. The 401 keeps its `WWW-Authenticate` challenge — see `refusedRequestMiddleware`.
    --
    -- Nothing about a request changed, and no status moved. What changed is that a generated client
    -- has a branch for each of these and can read a code out of all of them.
    & info . Data.Swagger.version .~ "3.6.0"
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
    -- Two facts under one status, and the codes are what tells them apart: a referenced entity the
    -- handler looked for and did not find, or a path the router never matched. Only the second has a
    -- code from this library's vocabulary (`route_not_found`); the first carries whichever
    -- `TxBuildingException` tag the lookup raised, like every other handler error here.
    & allOperations . responses . at 404 ?~ Inline (mempty {_responseDescription = "Referenced entity not found (profile, attestation, or NFT), or no route matches the path. Code: route_not_found for the latter, a TxBuildingException tag for the former."})
    & allOperations . responses . at 503 ?~ Inline (mempty {_responseDescription = "Protocol is paused or deployed validator scripts are not yet available"})
    -- The five statuses the service could always return and the document never admitted to. A
    -- generated client branches on what it is given, so an undeclared status is a branch that does
    -- not exist — and 502 was the one that mattered: it is what a submission the node rejected
    -- answers, which is NOT the caller's fault and is the one error worth retrying.
    --
    -- 405 and 406 are servant's and not a handler's, which is why they are declared on every
    -- operation: they are a property of asking for a path the wrong way, and every path can be asked
    -- for the wrong way. Both carry the same `{code, message}` body as everything else here —
    -- `method_not_allowed`, `not_acceptable`, from `refusedRequestMiddleware`.
    --
    -- THE 415 IS NOT ONE OF THEM, and used to be declared as if it were. It comes from `ReqBody`'s
    -- content-type check, so only a route that HAS a body can produce it — see
    -- `requestBodyOperations`, which is the eleven of them. On `allOperations` it was published on
    -- four routes that cannot answer it, which is the `invalid_asset_class` mistake and is now
    -- fixed in the same spirit that one was. It also used to be declared with no code named, because
    -- it was the one refusal still answering with an empty body; it is a row in that middleware's
    -- table now, so it names its code like the rest. See the note on `mkWebApp`.
    & allOperations . responses . at 405 ?~ Inline (mempty {_responseDescription = "Wrong HTTP method for this path. Code: method_not_allowed. Every write route is a POST; /health, /ready, /status and /tx-status are GETs."})
    & allOperations . responses . at 406 ?~ Inline (mempty {_responseDescription = "The Accept header asked for a media type this service does not produce; it serves application/json only. Code: not_acceptable."})
    & requestBodyOperations . responses . at 415 ?~ Inline (mempty {_responseDescription = "The request body was not sent as application/json. Set Content-Type: application/json. Code: unsupported_media_type."})
    -- THE AUTH BOUNDARY, on the twelve authenticated routes and not on the three public ones — see
    -- `authenticatedOperations` for why this is not `allOperations`.
    --
    -- 401 USED TO BE ABSENT ALTOGETHER, justified by `PublicAPI` excluding the `BasicAuth`
    -- combinator. That argument covered /health, /ready and /status and silently covered the twelve
    -- routes it should not have: a client generated from this document had no branch for the first
    -- response it was ever going to receive. Measured: `POST /build-tx` with no credentials is 401,
    -- and with WRONG credentials is 403 — two statuses, because servant's `BasicAuth` answers with
    -- two, and neither was declared or carried a body.
    & authenticatedOperations . responses . at 401
      ?~ Inline (mempty {_responseDescription = "No credentials, or credentials that could not be read. Code: unauthenticated. The response carries a WWW-Authenticate challenge naming the Basic realm; send HTTP Basic credentials."})
    & authenticatedOperations . responses . at 403
      ?~ Inline (mempty {_responseDescription = "Credentials were supplied and are not accepted. Code: credentials_rejected. This is an authentication failure under a 403 because that is the status servant's BasicAuth answers with; it is NOT a permission check, and this API has none."})
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
-- __No refusal this service makes is bodiless any more, and the last three closed together.__ The
-- 415 (a POST whose @Content-Type@ is not @application\/json@) and the 401\/403 pair from the
-- @BasicAuth@ combinator are three more rows in 'refusedRequestMiddleware'\''s own table, which is
-- in @webapi-lib@ — adding them here would be the second copy this comment exists to avoid. The
-- 401's @WWW-Authenticate@ challenge survives the rewrite, which is why that table carries the
-- refused response's headers instead of building fresh ones.
--
-- The unrouted 404 is closed differently, and deliberately: it is the only one servant gives a hook
-- for — @notFoundErrorFormatter@, the fourth field of @ErrorFormatters@ — so
-- 'palmaresErrorFormatters' answers it with @route_not_found@ and this service gains that from the
-- context entry below rather than from the middleware.
--
-- Which means the ordering note above now matters for the 401 as well: the middleware sits inside
-- CORS, so a browser that is refused for credentials can still read the body it is given.
mkWebApp :: CorsConfig -> InteractionAppContext -> Application
mkWebApp corsCfg ctx =
  mkCorsMiddleware corsCfg $
    refusedRequestMiddleware $
      provideOptions proxyPublicAPI $
        serveWithContext proxyFullAPI ctxEntries hoistedServer
  where
    ctxEntries = authCheck (authContext ctx) :. palmaresErrorFormatters :. EmptyContext
    hoistedServer = hoistServerWithContext proxyFullAPI proxyServerContext (runInteractionAppMonad ctx) fullServer
