{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Shared HTTP error construction and client-facing sanitization for the API
-- servers. Full internal detail is logged by callers; clients receive only the
-- generic messages produced here.
--
-- Every error body this module builds is JSON of the shape @{"code": …, "message": …}@, with
-- @application\/json@ on the response. Two constructors, because there are two code vocabularies:
-- 'mkServantErr' for the read surface's 'ErrorCode', and 'mkServantErrBody' for the write
-- surface, whose codes come from @TxBuildingException@ and are not this library's business (it
-- keeps no project-library dependency).
module Palmares.WebAPI.Errors
  ( mkServantErr,
    mkServantErrBody,
    errorCodeFromParserMessage,
    genericErrorMessage,
    palmaresErrorFormatters,
    refusedRequestMiddleware,
    internalErrorResponse,
  )
where

import Data.Aeson (encode)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types (Status (..))
import Network.HTTP.Types.Header (hContentLength, hContentType)
import Network.Wai (Middleware, Response, responseHeaders, responseLBS, responseStatus)
import Palmares.WebAPI.Envelope (ApiError (..), ErrorCode (..), errorCodeFromText, errorCodeToHttpStatus)
import Servant

-- | Build a 'ServerError' for an HTTP status code with the given JSON body.
--
-- Unlike a naive mapping, non-4xx statuses are not collapsed to 400: a 5xx stays a 5xx (fixes
-- probe failures being reported as 400).
mkServantErrBody :: Int -> ByteString -> ServerError
mkServantErrBody status body =
  base {errBody = body, errHeaders = [(hContentType, "application/json")]}
  where
    base = case status of
      400 -> err400
      -- The five statuses servant's own layers raise and no handler does — the auth combinator's
      -- 401 and 403, the router's 405, 406 and 415. They are all in 'errorCodeToHttpStatus', and
      -- without an arm here a caller that passed one of them through 'mkServantErr' would have
      -- served it as a 500 by falling through to the catch-all. That is not hypothetical: it is
      -- what the 405 did before it had a line.
      401 -> err401
      403 -> err403
      404 -> err404
      405 -> err405
      406 -> err406
      415 -> err415
      429 -> err429
      500 -> err500
      502 -> err502
      503 -> err503
      _ -> err500

-- | Build a 'ServerError' carrying an 'ApiError' body for a read-surface 'ErrorCode'.
--
-- The status is passed rather than derived from the code so a caller can serve a code under a
-- status the code does not imply; @errorCodeToHttpStatus@ is the default a caller should use.
mkServantErr :: Int -> ErrorCode -> ServerError
mkServantErr status code = mkServantErrBody status (encode (ApiError code (genericErrorMessage code)))

-- | The 'ErrorCode' inside the message a @FromHttpApiData@ parser failed with.
--
-- Every @parseUrlPiece@ and @parseQueryParam@ in this codebase returns the error CODE as its
-- message, so that the code survives the trip out through servant and back into an error
-- formatter. What does NOT survive is the message being the WHOLE string: servant hands the two
-- failure sites over differently —
--
--   * a CAPTURE's message arrives verbatim, @\"invalid_drep_id\"@;
--   * a QUERY PARAMETER's is wrapped, @\"Error parsing query parameter drep_id failed:
--     invalid_drep_id\"@.
--
-- So the code is read from after the last colon. MEASURED, by the smoke suite:
-- @\/delegations?drep_id=nonsense@ and @\/treasury-withdrawals?gov_action_id=nope@ both answered
-- @invalid_parameter@ while the identical mistake on @\/drep\/{id}@ answered @invalid_drep_id@ —
-- a true answer that told a client nothing, from the one of the two cases nobody had exercised.
--
-- A message with no colon is returned unchanged by 'T.takeWhileEnd', so the capture case reads
-- exactly as it did before. Anything unrecognised is 'InvalidParameter', which is true of it.
errorCodeFromParserMessage :: String -> ErrorCode
errorCodeFromParserMessage =
  errorCodeFromText . T.strip . T.takeWhileEnd (/= ':') . T.pack

-- | Generic, non-sensitive client-facing message for an error code.
--
-- Total over 'ErrorCode' on purpose: a new code with no message would otherwise silently inherit
-- a neighbour's wording, and the message is what a human reads when the code means nothing to
-- them. None of these names a table, a column, a host or an internal limit.
genericErrorMessage :: ErrorCode -> Text
genericErrorMessage = \case
  -- Not "a query parameter": this code is also what a bad PATH SEGMENT and a malformed request
  -- BODY answer with, now that both services install `palmaresErrorFormatters`. Rewording is what
  -- the code/message split is for — a client matches on `invalid_parameter` and this line is for a
  -- person, who was being sent to look at the query string for a broken JSON body.
  InvalidParameter -> "A query parameter, path segment or request body is not valid"
  QueryTooShort -> "The search query is too short"
  QueryTooLong -> "The search query is too long"
  OffsetTooLarge -> "The offset is beyond the allowed range"
  LimitTooLarge -> "The limit is beyond the allowed range"
  InvalidCursor -> "The cursor is not one this endpoint issued"
  BothCursorsGiven -> "Give either `before` or `since`, not both"
  InvalidDrepId -> "Not a DRep identifier"
  InvalidGovActionId -> "Not a governance action identifier"
  InvalidAssetClass -> "Not an asset class"
  InvalidCredential -> "Not a CIP-129 governance credential: expected drep1y..., cc_cold1... or cc_hot1..."
  InvalidTimeRange -> "The time range is empty or reversed"
  InvalidEpochRange -> "The epoch range is empty or reversed"
  -- Neither of these names the realm, the configured username, or which of the two credentials was
  -- wrong. The 401's message points at the header because the challenge beside it says how; the
  -- 403's says only that what arrived was refused, because "wrong password" told to an unauthorised
  -- caller is an oracle for guessing the username.
  Unauthenticated -> "No credentials were supplied, or they could not be read"
  CredentialsRejected -> "Those credentials are not accepted"
  MethodNotAllowed -> "That method is not served on this path"
  NotAcceptable -> "This route cannot produce any of the media types in Accept"
  UnsupportedMediaType -> "The request body must be sent as application/json"
  -- Deliberately not "not found": nothing was looked up. The sentence names the PATH, because that
  -- is the only thing a caller can act on — every other 404 here invites a different identifier,
  -- and this one invites a different URL.
  RouteNotFound -> "That path is not served"
  DrepNotFound -> "No DRep with that identifier"
  GovActionNotFound -> "No governance action with that identifier"
  SpoNotFound -> "No stake pool with that identifier"
  CommitteeNotFound -> "No committee member with that identifier"
  ProfileNotFound -> "No profile with that identifier"
  AttestationNotFound -> "No attestation with that identifier"
  DisputeNotFound -> "No dispute with that identifier"
  RateLimited -> "Too many requests"
  NotReady -> "Service temporarily unavailable"
  IndexerBehind -> "The chain index is too far behind to answer"
  DbUnavailable -> "Service temporarily unavailable"
  InternalError -> "Internal server error"

-- | The formatters both services install, so a request servant refuses BEFORE a handler runs still
-- answers with the documented @{code, message}@ body.
--
-- __interaction-api installed none at all__, and it is the service where it matters most: a
-- malformed or incomplete JSON body on any of its twelve POST routes — the most common client error
-- on a write API — came back as @text\/plain@ with no @code@ to branch on, and
-- @GET \/tx-status\/nope@ answered @400 Invalid transaction ID: nope@ as plain text. query-api had
-- its own private copy of this value, which is how one service ended up with it and the other
-- without; one definition, in the library that owns the error vocabulary.
--
-- A BODY that does not parse is 'InvalidParameter' and deliberately not whatever aeson said: aeson's
-- message is a path into the document, which is useful to a person and is not a code a client can
-- switch on. The two parser hooks below keep going through 'errorCodeFromParserMessage', because a
-- capture and a query parameter DO carry the repo's own code tags in their messages.
--
-- __The unrouted 404 is the fourth hook, and it is set here rather than in a middleware precisely
-- because servant HAS a hook for it.__ 405 and 406 do not have one and go through
-- 'refusedRequestMiddleware'; this one is @notFoundErrorFormatter@, which the router consults when
-- no path matched. Measured before it, on both services: @GET \/nope@ answered 404 with zero bytes
-- and no content type, because servant's default here is a bare @err404@. Setting it in this one
-- shared value is what gives both services the fix — interaction-api installed no formatters at all
-- until recently and query-api kept a private copy, which is exactly how the two drifted.
--
-- The request is ignored: the answer cannot name what was missing without echoing a client-supplied
-- path back into a response body, and the path is already in the request line the client sent.
palmaresErrorFormatters :: ErrorFormatters
palmaresErrorFormatters =
  defaultErrorFormatters
    { -- One hook covers a failing Capture AND a failing QueryParam: servant has no separate
      -- queryParseErrorFormatter to set.
      urlParseErrorFormatter = fromParserMessage,
      headerParseErrorFormatter = fromParserMessage,
      bodyParserErrorFormatter = \_ _ _ -> mkServantErr 400 InvalidParameter,
      notFoundErrorFormatter = const (mkServantErr (errorCodeToHttpStatus RouteNotFound) RouteNotFound)
    }
  where
    fromParserMessage _ _ msg =
      let code = errorCodeFromParserMessage msg
       in mkServantErr (errorCodeToHttpStatus code) code

-- | Give the five refusals servant decides BEFORE a handler the same @{code, message}@ body as
-- every other non-2xx response.
--
-- __Middleware rather than a formatter, because servant offers no hook for any of them.__
-- 'ErrorFormatters' has four fields: a failing URL piece, a failing header, a malformed body — all
-- three of which happen while a handler is being reached — and an unrouted path, which
-- 'palmaresErrorFormatters' answers with @route_not_found@. These five are decided earlier, each as
-- a @FailFatal@ that no formatter is consulted for, and there is no
-- @methodNotAllowedErrorFormatter@ or @unauthorizedErrorFormatter@ to set:
--
--   * 405, from the router's method check, and 406, from @Verb@'s @AllCTRender@ when content
--     negotiation finds no match;
--   * 415, from @ReqBody@'s own content-type check;
--   * 401 and 403, from the @BasicAuth@ combinator — which is the one pair that is NOT the router,
--     and the reason this function's name says \"refused request\" rather than \"router\".
--
-- Measured against the deployed binaries, every one with a zero-byte body and __no content type at
-- all__, so a client doing @res.json()@ on a failure path threw a parse error instead of reading a
-- code: @POST \/dreps@ → 405; @GET \/profiles?limit=1@ with @Accept: text\/csv@ → 406;
-- @POST \/build-tx@ with no credentials → 401; the same with a wrong password → __403__; and with
-- credentials but @Content-Type: text\/plain@ → 415. Six list routes serve CSV and seven do not, so
-- the 406 is a mistake a real client makes; the 401\/403 pair is the mistake EVERY client makes
-- first, on the twelve routes behind auth.
--
-- __The absence of a content type is the test__, and it is deliberately not a status test alone.
-- Every response these services mean to send carries one: a handler's own 4xx goes through
-- 'mkServantErr', which sets @application\/json@, and a success carries whatever was negotiated.
-- servant's own refusals carry no content type — 401 carries a @WWW-Authenticate@ and the rest carry
-- @errHeaders = []@. So rewriting only the content-type-less ones cannot touch a body a handler
-- built, which a bare @status == 403@ test very much could: 403 is a status a handler could
-- plausibly raise later, and this guard is what keeps that future handler's body intact.
--
-- The body comes from 'mkServantErr' rather than being assembled here, so there is exactly one
-- place an 'ApiError' is constructed from a code and nothing can drift between the two.
-- The continuation is @send@ and not WAI's conventional @respond@, because this module imports
-- 'Servant', which exports a @respond@ of its own ('Servant.Server.UVerb') — same name, unrelated
-- function, and shadowing it is a warning rather than a bug only because nothing here wants the
-- other one.
refusedRequestMiddleware :: Middleware
refusedRequestMiddleware app req send = app req (send . reshape)
  where
    reshape res = case (statusCode (responseStatus res), lookup hContentType (responseHeaders res)) of
      (401, Nothing) -> refusal res Unauthenticated
      (403, Nothing) -> refusal res CredentialsRejected
      (405, Nothing) -> refusal res MethodNotAllowed
      (406, Nothing) -> refusal res NotAcceptable
      (415, Nothing) -> refusal res UnsupportedMediaType
      _ -> res

    -- __The refused response's own headers are KEPT, and on the 401 that is load-bearing.__
    -- servant's @BasicAuth@ raises @err401 { errHeaders = [mkBAChallengerHdr realm] }@, so the
    -- refusal carries @WWW-Authenticate: Basic realm="user-realm"@ — the header that tells a client
    -- HOW to authenticate, and the only reason a browser offers a credential prompt at all.
    -- Building the replacement from 'mkServantErr' alone, as the 405\/406 form of this function
    -- did, would have dropped it: @mkServantErr@'s @errHeaders@ is exactly
    -- @[(hContentType, "application\/json")]@ and nothing else. Trading a readable body for a
    -- broken auth handshake would have been a worse bug than the empty body it fixed.
    --
    -- The carried list goes FIRST and the JSON content type last, which is safe for the same reason
    -- the match above is keyed on it: there is no content type in the carried list, or this response
    -- would not be here.
    --
    -- @Content-Length@ is dropped because the body is no longer the one it measured. Servant's error
    -- responses do not set it (warp derives it from the lazy body), so this is a framing guard
    -- rather than an observed bug — and a stale @Content-Length@ truncates a response rather than
    -- failing it, which is the kind of bug that is found in a client and not here.
    refusal res code = serverErrorToResponse (e {errHeaders = carried <> errHeaders e})
      where
        e = mkServantErr (errorCodeToHttpStatus code) code
        carried = filter ((/= hContentLength) . fst) (responseHeaders res)

-- | The response warp sends when a request dies of an uncaught exception.
--
-- Warp's default is @text\/plain@ with the words @Something went wrong@, and it is produced OUTSIDE
-- the middleware stack — when the application throws, the continuation 'refusedRequestMiddleware'
-- wraps is never called, so nothing in WAI can reshape it. @setOnExceptionResponse@ is the only
-- hook, which is why this is a value for a caller to install rather than another middleware.
--
-- A 500 is a bug here and not a condition a client can fix: a database that is unreachable or a
-- view that a db-sync migration dropped is caught in 'QueryAppMonad.runRead' and served as @503
-- db_unavailable@. So this is the shape of the last resort, and the reason it exists at all is
-- that @{code, message}@ is published as the body of EVERY non-2xx response — a client that
-- special-cases one status because it is the only one that is not JSON has to be told which.
internalErrorResponse :: Response
internalErrorResponse = serverErrorToResponse (mkServantErr 500 InternalError)

-- | A 'ServerError' as a WAI 'Response', so one body builder serves both layers.
serverErrorToResponse :: ServerError -> Response
serverErrorToResponse e =
  responseLBS
    (Status (errHTTPCode e) (BS8.pack (errReasonPhrase e)))
    (errHeaders e)
    (errBody e)
