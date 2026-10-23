module Palmares.TxBuilding.Exceptions where

import Control.Exception
import GHC.Generics (Generic)
import GeniusYield.HTTP.Errors (IsGYApiError)
import GeniusYield.Types (GYScriptHash)
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
  | -- | The claimed period ends before it begins.
    --
    -- The ONLY check the claimed period gets, and it is off-chain only. The minting policy carries
    -- the period through unvalidated on purpose — nothing on chain can establish when an affiliation
    -- began, and a @from <= to@ check would be ExUnits on every issue for a nonsense the subject
    -- would have to counter-sign about itself. But a client that transposed two dates deserves to be
    -- told so, which an unchecked field cannot do.
    AttestationPeriodInverted
  | -- | The attestation names a subject profile that does not exist.
    --
    -- Off-chain only, and that is not an oversight: the minting policy checks only that the subject
    -- asset class carries the protocol currency symbol (@Mg@), and nothing in this protocol burns —
    -- so an attestation about a non-existent subject is a record that is permanently pending (no
    -- subject can counter-sign it) and permanently unremovable. The chain cannot be made to refuse
    -- it without resolving a 'ProfileId' into a UTxO on chain, so the write path refuses it here,
    -- where the client can be told.
    SubjectProfileNotFound
  | -- | __Claim errors.__ The credential is not a CIP-129 identifier this protocol can claim.
    --
    -- A CIP-105 DRep id or a bare hex hash lands here on purpose: neither carries the header byte
    -- that says whether the credential is a key or a script, and the claim rule is a different rule
    -- for each.
    CredentialMalformed
  | -- | A script credential that cannot be proven controlled in one transaction.
    --
    -- The spec's claim rule is \"prove you can spend as that credential\", and for a script that
    -- means the transaction spends an input the script governs. A Plutus script that only votes or
    -- withdraws holds no UTxO at its own address, so there is nothing to spend — the documented
    -- limitation, refused HERE rather than left to fail inside the balancer, which is the whole
    -- point of looking the UTxO up before building. Carries the script hash because a claim may name
    -- a script the caller never looked at.
    ScriptCredentialHasNoUtxo GYScriptHash
  | -- \* Dispute Errors
    DisputeNotFound
  | -- | A dispute is already open against this attestation.
    --
    -- __A courtesy, not a protocol rule.__ Nothing on chain bounds the number of disputes against
    -- one attestation — that would need an index UTxO every dispute had to contend for — and the
    -- deposit is what bounds the spam, since N disputes cost N deposits. This refuses the duplicate a
    -- human would not have meant; a client building its own transaction is not refused.
    DisputeAlreadyOpen
  | -- | The dispute already carries a verdict. @D3@ refuses it on chain as well.
    DisputeAlreadyResolved
  | -- | The dispute's deadline has not passed, so there is nothing to expire yet. @D9@ refuses it on
    -- chain as well.
    --
    -- A 400 and not a 403: nobody lacks permission here — @ExpireDispute@ needs none — the request
    -- is simply early. The deadline is in the dispute's own datum, so a client can read it and wait.
    DisputeNotStaleYet
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
  displayException SubjectProfileNotFound =
    "The subject profile does not exist. An attestation about a profile that was never claimed can \
    \never be counter-signed, so it would stay pending forever and nothing can remove it."
  displayException CredentialMalformed =
    "The credential must be a CIP-129 identifier (drep1…, cc_cold1…, cc_hot1…). A CIP-105 id or a \
    \bare hex hash carries no header byte, so it cannot say whether the credential is a key or a \
    \script — and the claim is a different proof for each."
  displayException (ScriptCredentialHasNoUtxo sh) =
    "No spendable UTxO at the address of script "
      <> show sh
      <> ", so this transaction cannot prove control of that script credential. The fix is one \
         \transaction: send a UTxO to that script address, then claim. A script witness must also be \
         \supplied, because the ledger has to be able to spend that input."
  displayException AttestationPeriodInverted =
    "claimed_period ends before it begins. Send [from, to] with from <= to, or omit the field \
    \entirely — a period must have both bounds or neither."
  displayException AttestationOtherMetadataReservedKeys =
    "other_metadata must not use reserved keys: name, description, image (CIP-68 standard fields)"
  displayException DisputeNotFound = "Dispute not found"
  displayException DisputeAlreadyOpen =
    "A dispute is already open against this attestation. Wait for it to be resolved before opening \
    \another; this is an off-chain courtesy, not a protocol rule."
  displayException DisputeAlreadyResolved = "Dispute already carries a verdict and cannot be resolved twice"
  displayException DisputeNotStaleYet = "Dispute cannot be expired yet: its deadline has not passed"
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
txBuildingExceptionToHttpStatus SubjectProfileNotFound = 404
txBuildingExceptionToHttpStatus DisputeNotFound = 404
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
