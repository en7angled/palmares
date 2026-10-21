module Palmares.TxBuilding.Exceptions where

import Control.Exception
import GHC.Generics (Generic)
import GeniusYield.HTTP.Errors (IsGYApiError)
import Prelude

------------------------------------------------------------------------------------------------

-- * Offchain Transaction Building Exceptions

------------------------------------------------------------------------------------------------

-- | Exceptions raised during offchain transaction building and lookups.
data TxBuildingException
  = -- \* Profile Lookup Errors
    ProfileNotFound
  | WrongProfileType
  | -- \* Attestation Errors
    AttestationNotFound
  | AttestationAlreadyAccepted
  | -- | @other_metadata@ keys must not duplicate CIP-68 standard keys @name@, @description@, or @image@.
    AttestationOtherMetadataReservedKeys
  | -- | The attestation date is not inside the transaction's validity interval.
    --
    -- The off-chain half of inherited fix #4. The minting policy requires the date to be CONTAINED in
    -- the validity interval, which this path builds from the chain tip; a caller-supplied date outside
    -- that window would otherwise fail as a script error, which reads to a client like a bug in the
    -- protocol rather than a bad request. So it is refused here, as a 400, before anything is built.
    AttestationDateOutOfRange
  | -- \* Oracle Errors
    OracleNotFound
  | OracleDatumInvalid
  | ProtocolPaused
  | -- \* Script / Infrastructure Errors
    DeployedScriptsNotReady
  | -- \* UTxO / Asset Errors
    InvalidAssetClass
  | NFTNotFound
  | MultipleUtxosFound
  | DatumParseError
  | -- \* Cleanup Errors
    NoDustFound
  deriving stock (Generic, Show, Eq)

instance Exception TxBuildingException where
  displayException :: TxBuildingException -> String
  displayException ProfileNotFound = "Profile not found"
  displayException WrongProfileType = "Wrong profile type"
  displayException AttestationNotFound = "Attestation not found"
  displayException AttestationAlreadyAccepted = "Attestation is already accepted"
  displayException AttestationDateOutOfRange =
    "The attestation date must be within the transaction validity window (roughly the next 7 hours of \
    \chain time). An attestation's date is when it is issued; an earlier event date is self-reported \
    \and belongs in other_metadata."
  displayException AttestationOtherMetadataReservedKeys =
    "other_metadata must not use reserved keys: name, description, image (CIP-68 standard fields)"
  displayException OracleNotFound = "Oracle UTxO not found"
  displayException OracleDatumInvalid = "Oracle datum invalid or unparseable"
  displayException ProtocolPaused = "Protocol is paused"
  displayException DeployedScriptsNotReady = "Deployed scripts are not ready"
  displayException InvalidAssetClass = "Invalid asset class"
  displayException NFTNotFound = "UTxO with this NFT not found"
  displayException MultipleUtxosFound = "Multiple UTxOs found for this asset class"
  displayException DatumParseError = "UTxO datum is missing or unparseable"
  displayException NoDustFound = "No dust UTxOs found at validator addresses"

instance IsGYApiError TxBuildingException

------------------------------------------------------------------------------------------------

-- * HTTP Status Mapping

------------------------------------------------------------------------------------------------

-- | Map a 'TxBuildingException' to the appropriate HTTP status code.
-- Used by the interaction API to return structured error responses.
txBuildingExceptionToHttpStatus :: TxBuildingException -> Int
txBuildingExceptionToHttpStatus ProfileNotFound = 404
txBuildingExceptionToHttpStatus AttestationNotFound = 404
txBuildingExceptionToHttpStatus AttestationAlreadyAccepted = 400
txBuildingExceptionToHttpStatus AttestationDateOutOfRange = 400
txBuildingExceptionToHttpStatus AttestationOtherMetadataReservedKeys = 400
txBuildingExceptionToHttpStatus OracleNotFound = 404
txBuildingExceptionToHttpStatus DeployedScriptsNotReady = 503
txBuildingExceptionToHttpStatus ProtocolPaused = 503
txBuildingExceptionToHttpStatus NoDustFound = 404
txBuildingExceptionToHttpStatus NFTNotFound = 404
txBuildingExceptionToHttpStatus OracleDatumInvalid = 500
txBuildingExceptionToHttpStatus DatumParseError = 500
txBuildingExceptionToHttpStatus _ = 400

-- | Stable, machine-readable error code for a 'TxBuildingException' — the
-- Clients should match on this instead of the human-readable message text,
-- which is subject to rewording. Derived from the (stable) derived 'Show'.
txBuildingExceptionCode :: TxBuildingException -> String
txBuildingExceptionCode = takeWhile (/= ' ') . show
