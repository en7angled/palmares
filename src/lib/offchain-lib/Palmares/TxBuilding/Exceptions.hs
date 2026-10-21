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
  | -- | The claimed period ends before it begins.
    --
    -- The ONLY check the claimed period gets, and it is off-chain only. The minting policy carries
    -- the period through unvalidated on purpose — nothing on chain can establish when an affiliation
    -- began, and a @from <= to@ check would be ExUnits on every issue for a nonsense the subject
    -- would have to counter-sign about itself. But a client that transposed two dates deserves to be
    -- told so, which an unchecked field cannot do.
    AttestationPeriodInverted
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
    \chain time). An attestation's date is when it is ISSUED. To record something that happened \
    \earlier, send claimed_period instead: it is published as self-reported and is never presented as \
    \chain-verified."
  displayException AttestationPeriodInverted =
    "claimed_period ends before it begins. Send [from, to] with from <= to, or omit the field \
    \entirely — a period must have both bounds or neither."
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
txBuildingExceptionToHttpStatus AttestationPeriodInverted = 400
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
