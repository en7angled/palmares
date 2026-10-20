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
    genericErrorMessage,
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Network.HTTP.Types.Header (hContentType)
import Palmares.WebAPI.Envelope (ApiError (..), ErrorCode (..))
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
      404 -> err404
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

-- | Generic, non-sensitive client-facing message for an error code.
--
-- Total over 'ErrorCode' on purpose: a new code with no message would otherwise silently inherit
-- a neighbour's wording, and the message is what a human reads when the code means nothing to
-- them. None of these names a table, a column, a host or an internal limit.
genericErrorMessage :: ErrorCode -> Text
genericErrorMessage = \case
  InvalidParameter -> "A query parameter is not valid"
  QueryTooShort -> "The search query is too short"
  QueryTooLong -> "The search query is too long"
  OffsetTooLarge -> "The offset is beyond the allowed range"
  LimitTooLarge -> "The limit is beyond the allowed range"
  InvalidCursor -> "The cursor is not one this endpoint issued"
  BothCursorsGiven -> "Use either a cursor or an offset, not both"
  InvalidDrepId -> "Not a DRep identifier"
  InvalidGovActionId -> "Not a governance action identifier"
  InvalidAssetClass -> "Not an asset class"
  InvalidTimeRange -> "The time range is empty or reversed"
  InvalidEpochRange -> "The epoch range is empty or reversed"
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
