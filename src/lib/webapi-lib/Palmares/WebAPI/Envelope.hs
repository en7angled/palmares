{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The page envelope and the error body: the two shapes every API response is wrapped in.
--
-- __Why these live in @webapi-lib@__ and not beside the DTOs they wrap: this library keeps no
-- project-library dependency, and @offchain-lib@ does not depend on it either. A type used both
-- by 'Palmares.WebAPI.Errors.mkServantErr' ('ApiError', 'ErrorCode') and by the CSV renderer's
-- @MimeRender CSV (Page a)@ instance ('Page', and 'Cursor' through 'pageNextCursor') can
-- therefore only live here — anywhere else and that instance would be an orphan declared in
-- neither the type's library nor the class's.
-- @Palmares.DomainTypes.Transfer.QueryResponses@ re-exports these names so a DTO consumer still
-- imports one module.
module Palmares.WebAPI.Envelope
  ( Cursor (..),
    Page (..),
    ApiError (..),
    ErrorCode (..),
    errorCodeToHttpStatus,
    errorCodeFromText,
  )
where

import Data.Aeson (Value (String), toJSON)
import Data.Aeson.Types qualified as AesonTypes
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Swagger (NamedSchema (..), SchemaOptions, ToSchema (..), genericDeclareNamedSchema)
import Data.Swagger.SchemaOptions (fromAesonOptions)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable, typeRep)
-- Open, as everywhere else in this repository, and it is also where Generic, FromJSON and ToJSON
-- come from below: re-importing those three from their own modules is what -Wall called redundant.
import Deriving.Aeson

-- | An opaque position in a keyset-paged feed. Clients echo it back and never parse it.
--
-- Opaque because its contents are the feed's business: @palmares.activity@ needs four components
-- to order its rows totally, and a client that had learned to read three of them would break
-- when the fourth was added. It is a string in both directions and nothing more.
newtype Cursor = Cursor {unCursor :: Text}
  deriving stock (Show, Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

instance ToSchema Cursor where
  declareNamedSchema _ = declareNamedSchema (Proxy @Text)

-- | One page of results.
--
-- @total@ is nullable, and that is a contract rather than an oversight: a keyset-paged feed
-- cannot count its own tail without a second full scan, so @\/activity@ serves @null@ there. The
-- alternative conventions — omitting the field, or sending @-1@ — both make a client that did not
-- read the documentation render something wrong, while @null@ makes it render nothing.
--
-- @limit@ and @offset@ are the APPLIED values, after clamping, not the requested ones. A client
-- that asked for 10,000 rows and got 200 can see that from the response instead of concluding the
-- server lost its data.
data Page a = Page
  { pageItems :: [a],
    pageTotal :: Maybe Int,
    pageLimit :: Int,
    pageOffset :: Int,
    pageNextCursor :: Maybe Cursor
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "page", CamelToSnake]] (Page a)

-- | The @mkStripPrefixSchemaOptions "page"@ body, inlined: that helper lives in @offchain-lib@,
-- which is unreachable from this library by design.
pageSchemaOptions :: SchemaOptions
pageSchemaOptions =
  fromAesonOptions
    AesonTypes.defaultOptions
      { AesonTypes.fieldLabelModifier = AesonTypes.camelTo2 '_' . drop (length ("page" :: String))
      }

-- | __The schema is named per element type, and that is the whole of this instance.__
--
-- @genericDeclareNamedSchema@ names a schema after the DATATYPE and ignores its type argument, so
-- every @Page X@ declared itself as @#\/definitions\/Page@ and the last registration won. Measured
-- on the committed document: 15 of 29 routes @$ref@-ed one @Page@ whose @items@ were
-- @DisputeRow@ — so a generated client typed @\/dreps@, @\/votes@, @\/gov-actions@ and eleven more
-- as lists of disputes and failed to deserialise every row. That file is the frontend's codegen
-- input, and @scripts\/check_swagger.sh@ could not catch it: it asserted paths, parameters,
-- @produces@ and enums, never that a list route's @items@ are the right DTO. It asserts that now.
--
-- The element type's name comes from 'Typeable' rather than from its own @ToSchema@ name, because
-- that is available without declaring the element schema a second time; every element here is a
-- plain DTO, so the two spellings coincide.
instance (ToSchema a, Typeable a) => ToSchema (Page a) where
  declareNamedSchema proxy = do
    NamedSchema _ s <- genericDeclareNamedSchema pageSchemaOptions proxy
    pure (NamedSchema (Just ("Page_" <> T.pack (show (typeRep (Proxy :: Proxy a))))) s)

-- | A stable machine-readable reason, paired with human text.
--
-- Clients match on @code@; @message@ is for display and may be reworded at any time. That split
-- is the whole point of the type — a client that string-matched the message would break on a
-- typo fix.
data ApiError = ApiError
  { apiErrorCode :: ErrorCode,
    apiErrorMessage :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "apiError", CamelToSnake]] ApiError

instance ToSchema ApiError where
  declareNamedSchema = genericDeclareNamedSchema apiErrorSchemaOptions
    where
      apiErrorSchemaOptions =
        fromAesonOptions
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = AesonTypes.camelTo2 '_' . drop (length ("apiError" :: String))
            }

-- | Every reason this API refuses or fails a request.
--
-- Grouped by the status they map to, and the grouping is the documentation: a reader can see at a
-- glance that nothing here is a 401 or a 403, because the read surface is public.
--
-- Four of them — @profile_not_found@, @attestation_not_found@, @dispute_not_found@ and
-- @rate_limited@ — are unreachable in Plan A. They are declared anyway because a code is part of
-- the published contract and adding one later is a Swagger change; a client that can already
-- handle @attestation_not_found@ needs no release when attestations land.
--
-- __That argument has a limit, and @invalid_asset_class@ was past it.__ A code nothing can produce
-- is a branch a client writes and never exercises, and after the attestation surface landed this
-- one was the only member of the 400 group with no site at all: the three asset-class captures parse
-- through Atlas's own @FromHttpApiData GYAssetClass@, whose failure message is not one of this
-- repo's tags, so a malformed profile id answered @invalid_parameter@ (measured). It is reachable
-- now, from @GET \/profiles\/by-user-token\/{asset-class}@, where \"not an asset class of this
-- registry's CIP-68 user form\" is exactly what it means and nothing else can say it. The three
-- captures still answer @invalid_parameter@; narrowing them needs a newtype in @offchain-lib@'s
-- @Core.Types@ with its own parser, which is a wider change than the code's absence justified.
data ErrorCode
  = -- 400: the request itself is wrong
    InvalidParameter
  | QueryTooShort
  | QueryTooLong
  | OffsetTooLarge
  | LimitTooLarge
  | InvalidCursor
  | BothCursorsGiven
  | InvalidDrepId
  | InvalidGovActionId
  | InvalidAssetClass
  | InvalidCredential
  | InvalidTimeRange
  | InvalidEpochRange
  | -- 405/406: the route exists, the request's method or its @Accept@ does not
    --
    -- __Both come out of servant's ROUTER, not out of a handler__, which is why they are the only
    -- two codes in this enum that no @throwApi@ ever raises: the router builds the response before
    -- a handler is reached and before 'Palmares.WebAPI.Errors.palmaresErrorFormatters' is
    -- consulted — servant has no formatter hook for either. They are carried by
    -- 'Palmares.WebAPI.Errors.refusedRequestMiddleware', which is the only producer.
    --
    -- Measured before it: @POST \/dreps@ and @GET \/profiles@ with @Accept: text\/csv@ both answered
    -- a bare @405@ \/ @406@ with __zero bytes and no content type__, so a browser client calling
    -- @.json()@ on either threw. @not_acceptable@ is the reachable one of the two in practice — six
    -- list routes serve CSV and seven do not, and asking the wrong one for it is the mistake
    -- @docs\/usecases\/api-screen-map.md@ §5.11 records a frontend already making.
    MethodNotAllowed
  | NotAcceptable
  | -- 404: the request is well formed and names nothing
    DrepNotFound
  | GovActionNotFound
  | SpoNotFound
  | CommitteeNotFound
  | ProfileNotFound
  | AttestationNotFound
  | DisputeNotFound
  | -- 429
    RateLimited
  | -- 503: the server is fine, its data is not yet
    NotReady
  | IndexerBehind
  | DbUnavailable
  | -- 500
    InternalError
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[CamelToSnake]] ErrorCode

instance ToSchema ErrorCode where
  declareNamedSchema = genericDeclareNamedSchema errorCodeSchemaOptions
    where
      errorCodeSchemaOptions =
        fromAesonOptions
          AesonTypes.defaultOptions
            { AesonTypes.constructorTagModifier = AesonTypes.camelTo2 '_'
            }

-- | The status each code is served with.
--
-- Total by construction: a new code without a status is a compile error here, which is why this
-- is a @case@ and not a lookup table with a fallthrough. A code served with the wrong status is
-- the kind of bug that only shows up in someone else's retry logic.
-- | Read an 'ErrorCode' back from its wire tag, defaulting to 'InvalidParameter'.
--
-- This exists for servant's routing layer. A failing @parseUrlPiece@ hands servant a @String@,
-- and servant builds its OWN 400 out of it — plain text, no @code@, bypassing
-- 'Palmares.WebAPI.Errors.mkServantErr' entirely. Measured: a DRep id with a broken bech32
-- checksum came back as @400@ with the body @Error parsing ...@, which no client could match on.
-- Since every @parseUrlPiece@ in this codebase returns the code's own tag as that string, an
-- error formatter can read it back here and serve the documented body.
errorCodeFromText :: Text -> ErrorCode
errorCodeFromText t =
  fromMaybe InvalidParameter (lookup t [(tag c, c) | c <- [minBound .. maxBound]])
  where
    tag c = case toJSON c of
      String s -> s
      _ -> ""

errorCodeToHttpStatus :: ErrorCode -> Int
errorCodeToHttpStatus = \case
  InvalidParameter -> 400
  QueryTooShort -> 400
  QueryTooLong -> 400
  OffsetTooLarge -> 400
  LimitTooLarge -> 400
  InvalidCursor -> 400
  BothCursorsGiven -> 400
  InvalidDrepId -> 400
  InvalidGovActionId -> 400
  InvalidAssetClass -> 400
  InvalidCredential -> 400
  InvalidTimeRange -> 400
  InvalidEpochRange -> 400
  MethodNotAllowed -> 405
  NotAcceptable -> 406
  DrepNotFound -> 404
  GovActionNotFound -> 404
  SpoNotFound -> 404
  CommitteeNotFound -> 404
  ProfileNotFound -> 404
  AttestationNotFound -> 404
  DisputeNotFound -> 404
  RateLimited -> 429
  NotReady -> 503
  IndexerBehind -> 503
  DbUnavailable -> 503
  InternalError -> 500
