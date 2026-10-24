module Palmares.TxBuilding.Exceptions where

import Control.Exception
import Data.Typeable (cast)
import GHC.Generics (Generic)
import GeniusYield.HTTP.Errors (IsGYApiError)
import GeniusYield.Transaction.Common (GYBuildTxError (..))
import GeniusYield.TxBuilder.Errors (GYTxMonadException (..))
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
  | -- | The named @deposit_to@ holds no UTxO this wallet can spend, so @Md8@ cannot be satisfied —
    -- @OF-02@.
    --
    -- __It exists because of what the failure used to look like.__ @Md8@ requires an input AT the
    -- deposit address, the builder forced none, and the balancer was simply asked for a transaction
    -- it could not make — so the error that reached the user was "Not enough ADA", about a deposit
    -- they had the funds for. A multi-address wallet met this BY DEFAULT, because @deposit_to@
    -- defaulted to the change address and a change address need not be an input.
    DepositAddressNotSpendable
  | -- | @deposit_to@ is a SCRIPT address, and a refund paid there is lost — @OC-06@.
    --
    -- @D4@ pays the refund as a datum-less output, which a key can spend and a script cannot. Three
    -- shapes followed and all three needed a script address: unspendable for ever at a Plutus
    -- address, sweepable dust at one of this protocol's own, and lockable inside the resolved record
    -- at the disputes address. @Mda@ refuses them on chain; this refuses them before the user signs.
    --
    -- Separate from 'DepositAddressNotSpendable' because the mistakes are different and the user
    -- needs to know which: that one is "you cannot spend from there", this one is "you can, and the
    -- refund would never come back".
    DepositAddressIsScript
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
  | -- | A resolution named @expired@, which is not a finding. @Da@ refuses it on chain as well.
    --
    -- Only the clock writes @expired@, through @ExpireDispute@ and only after the dispute's own
    -- deadline. An admin who wants a dispute closed without a finding waits for that deadline like
    -- anybody else — which is the whole guarantee D-A adds.
    DisputeVerdictNotAFinding
  | -- | @/issue-attestation@ was asked for a credential kind. @Mc2@ refuses it on chain as well,
    -- because this route names no credential and a 'CredentialClaim' with none is not a record.
    --
    -- Its own error and not a generic refusal, because the request is not wrong so much as sent to
    -- the wrong route: @/claim-credential@ and @/withdraw-credential@ are where those two kinds are
    -- built, and they are separate routes precisely because they take a credential and a witness.
    --
    -- This constructor replaced @ProfileClaimsNoCredential@, which belonged to the D-E revocation
    -- that ADR 0003 removed; it had no throw site left and its Haddock cited the burnt code @P8@.
    AttestationKindIsCredentialBinding
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
  displayException DepositAddressIsScript =
    "deposit_to is a script address. The deposit is refunded as a plain output with no datum, which \
    \a script cannot spend, so it would be lost — including at this protocol's own addresses. Name a \
    \key address, or omit deposit_to to use the one holding the profile's user NFT."
  displayException DepositAddressNotSpendable =
    "deposit_to names an address this wallet holds no spendable UTxO at, and the protocol requires \
    \the deposit address to be spent from in the same transaction (Md8). Omit deposit_to to use the \
    \address holding the profile's user NFT, which is always an input, or name an address you hold \
    \funds at."
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
  displayException AttestationKindIsCredentialBinding =
    "A credential binding is not issued here: use /claim-credential or /withdraw-credential, which \
    \take the credential and the witness that proves control of it"
  displayException DisputeVerdictNotAFinding = "A resolution must be a finding: only a passed deadline writes 'expired'"
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
--
-- __TOTAL, and no wildcard arm — that is the fix.__ This ended in @_ = 400@, which is defensible as
-- a default and indefensible as a MECHANISM. MEASURED on the 26 constructors of
-- 'TxBuildingException': twelve of them reached a client through that one line, and only five had
-- their status or their code asserted anywhere in the test suite (thirteen were not named in it at
-- all) — so a constructor added for a 404 or a 503 inherited a 400 in silence, and nothing could
-- tell a chosen 400 from an inherited one.
--
-- Enumerating every arm costs twelve lines once and buys the one thing a default cannot: GHC reports
-- a new constructor here, because @-Wall@ is on for every stanza in this project and this function
-- then has an incomplete pattern — so a new error's status is a decision somebody takes in a
-- reviewed diff instead of a value nobody picked. @UnitTests.WritePath@ pins the resulting table by
-- value, which is the half that catches a status being CHANGED rather than forgotten.
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
-- The twelve that used to arrive here through @_ = 400@. Every one of them IS a 400 — the request is
-- the thing that is wrong and the client is the one who can fix it — so the values below are what
-- the catch-all was already serving. What changed is that they are now written down:
--
--   * a 400 and not a 403 for 'DisputeNotStaleYet', because nobody lacks permission — @ExpireDispute@
--     needs none — the request is simply early, and the deadline is in the dispute's own datum;
--   * a 400 and not a 404 for 'ScriptCredentialHasNoUtxo', because the script exists and the fix is
--     to fund it, which is a thing the caller does rather than a thing that is missing;
--   * a 400 and not a 409 for the three "already" refusals: this API publishes no 409 anywhere, and
--     introducing one on three constructors would be a new status a client must learn for no new
--     decision — the @code@ is what distinguishes them and it always has been.
txBuildingExceptionToHttpStatus WrongProfileType = 400
txBuildingExceptionToHttpStatus AttestationKindIsCredentialBinding = 400
txBuildingExceptionToHttpStatus CredentialMalformed = 400
txBuildingExceptionToHttpStatus (ScriptCredentialHasNoUtxo _) = 400
txBuildingExceptionToHttpStatus DepositAddressNotSpendable = 400
txBuildingExceptionToHttpStatus DepositAddressIsScript = 400
txBuildingExceptionToHttpStatus DisputeAlreadyOpen = 400
txBuildingExceptionToHttpStatus DisputeAlreadyResolved = 400
txBuildingExceptionToHttpStatus DisputeVerdictNotAFinding = 400
txBuildingExceptionToHttpStatus DisputeNotStaleYet = 400
txBuildingExceptionToHttpStatus InvalidAssetClass = 400
txBuildingExceptionToHttpStatus MultipleUtxosFound = 400

-- | Stable, machine-readable error code for a 'TxBuildingException' — the
-- Clients should match on this instead of the human-readable message text,
-- which is subject to rewording. Derived from the (stable) derived 'Show'.
txBuildingExceptionCode :: TxBuildingException -> String
txBuildingExceptionCode = takeWhile (/= ' ') . show

------------------------------------------------------------------------------------------------

-- * Write-path failure classification — OF-05

------------------------------------------------------------------------------------------------

-- | The HTTP answer a write-path failure deserves.
--
-- A record rather than a tuple because the three travel together everywhere and the caller builds
-- one JSON body out of them.
data ApiFailure = ApiFailure
  { afStatus :: Int,
    -- | The stable code a client matches on.
    afCode :: String,
    afMessage :: String
  }
  deriving stock (Eq, Show)

-- | Classify __any__ exception the write path can throw into the answer a client can act on.
--
-- __Why this is one pure function.__ The translation used to live inside the interaction API's
-- handler, typed by its own patterns to 'GYTxMonadException', and it collapsed four different
-- failures into one answer (@OF-05@):
--
--   * every balancing failure became @400 InsufficientFunds@, "Not enough ADA in your wallet" —
--     INCLUDING a Plutus script refusing the transaction. A user told to add funds for an @Md8@ or a
--     @D7@ adds funds and is told the same thing again;
--   * anything that was not a 'GYTxMonadException' at all — a provider's HTTP failure, a submission
--     rejection — escaped the handler and reached Warp's default, which answers @text\/plain@
--     "Something went wrong" with no @code@ at all, under a 500 where a 502 is the truth.
--
-- Pure, total and exported so a test can pin the table: the audit asked for exactly that, and a
-- mapping nobody can call without an HTTP server is a mapping nobody tests.
--
-- __The script arm is the one that matters__, and it is why the validators keep their traces: a
-- refusal names the conjunct that refused. The trace codes are read out of the rendered exception by
-- 'traceCodesInRender' — see that function for why a render parse is the honest choice here.
classifyWriteFailure :: SomeException -> ApiFailure
classifyWriteFailure e
  -- Our own exceptions first: they already carry a code and a status.
  | Just (GYApplicationException appE) <- fromException @GYTxMonadException e,
    Just txEx <- cast appE =
      ApiFailure (txBuildingExceptionToHttpStatus txEx) (txBuildingExceptionCode txEx) (displayException txEx)
  -- A script refused the transaction. 400, because the transaction is the client's to fix, and the
  -- codes say what to fix.
  | not (null codes) =
      ApiFailure
        400
        "ScriptRefused"
        ( "A validator refused this transaction: "
            <> unwords codes
            <> ". These are on-chain trace codes; see docs/architecture/onchain-flows.md for what each one requires."
        )
  | Just gyEx <- fromException @GYTxMonadException e = fromGY gyEx
  -- Not a transaction-building exception at all. A submission rejected by the node or a provider
  -- that could not be reached is not the client's fault and not an internal fault either: 502 is the
  -- status that says "the thing upstream of me failed", and it is what the old code answered 500 to.
  | isProviderFailure = ApiFailure 502 "ProviderError" "The chain provider could not be reached or rejected the submission"
  | otherwise = ApiFailure 500 "InternalError" "Internal server error"
  where
    rendered = show e
    codes = traceCodesInRender rendered
    -- Matched on the render, for the same reason the trace codes are: `SubmitTxException` lives in
    -- Atlas's provider layer and every provider wraps its own client error in it, so the type is
    -- reachable but tells us nothing a string does not. A provider that invents a new exception type
    -- lands in `InternalError`, which is the safe direction: a 500 that should have been a 502 is a
    -- worse answer, not a wrong promise.
    isProviderFailure =
      any
        (`isInfixOfStr` rendered)
        ["SubmitTxException", "HttpExceptionRequest", "ConnectionFailure", "ResponseTimeout"]
    fromGY gyEx = case gyEx of
      -- Everything Atlas raises when the wallet cannot pay: no UTxO to spend, nothing to balance
      -- with, no collateral. These keep the answer they had, which was right for them.
      GYQueryUTxOException {} -> shortfall
      GYNoSuitableCollateralException {} -> shortfall
      GYBuildTxException buildErr -> case buildErr of
        GYBuildTxBalancingError {} -> shortfall
        GYBuildTxFeeUtxoAdaInsufficient {} -> shortfall
        GYBuildTxCollateralShortFall {} -> shortfall
        GYBuildTxNoSuitableCollateral -> shortfall
        -- The ExUnits and size ceilings are the client's problem and NOT a shortfall: adding ADA
        -- does nothing about either, which is precisely what the old answer told them to do.
        GYBuildTxExUnitsTooBig {} ->
          ApiFailure 400 "TxTooExpensive" "This transaction needs more execution units than the protocol allows"
        GYBuildTxSizeTooBig {} ->
          ApiFailure 400 "TxTooLarge" "This transaction is larger than the protocol allows"
        -- `GYBuildTxBodyErrorAutoBalance` with no trace codes in it: the ledger refused the BODY.
        -- Most of those shapes are a negative ADA balance, which is a shortfall, and the rest are
        -- malformations a client cannot act on differently — so this keeps the 400 it had rather
        -- than pretending to a precision the error does not carry. The script case, which is the
        -- one the audit is about, never reaches here: it is caught by the trace-code guard above.
        _ -> shortfall
      _ -> ApiFailure 500 "InternalError" "Internal server error"
    shortfall =
      ApiFailure
        400
        "InsufficientFunds"
        "Not enough ADA in your wallet to cover the deposit and transaction cost."

-- | The on-chain trace codes inside a rendered Plutus failure, in the order the script emitted them.
--
-- __A render parse, deliberately.__ cardano-api's @ScriptExecutionError@ carries the logs in a
-- @DebugPlutusFailure@ record, and reaching it means importing that constructor surface through two
-- layers of @TxBodyErrorAutoBalance@. The test suite has read these codes off the render since the
-- first negative test (@Test.Helpers.failedWithTrace@), roughly sixty cases depend on it, and those
-- cases are what keeps this parser honest — so there is one parser now instead of two, and the
-- emulator suite is its gate.
--
-- The failure mode is bounded in the right direction: a render change makes the list EMPTY, so a
-- script refusal degrades to the shortfall answer it used to give. It cannot produce a wrong code.
traceCodesInRender :: String -> [String]
traceCodesInRender rendered = case afterMarker rendered of
  Nothing -> []
  Just rest -> quoted (takeWhile (/= ']') rest)
  where
    marker = "dpfExecutionLogs = ["
    afterMarker s
      | marker `isPrefixOfStr` s = Just (drop (length marker) s)
      | null s = Nothing
      | otherwise = afterMarker (tail s)
    -- The logs render as a Haskell list of Text literals: ["D6","PT5"]. Anything else yields no
    -- codes rather than fragments of one.
    quoted s = case dropWhile (/= '"') s of
      [] -> []
      (_ : s') -> case break (== '"') s' of
        (code, []) -> [code | not (null code)]
        (code, _ : s'') -> (if null code then id else (code :)) (quoted s'')

isPrefixOfStr :: String -> String -> Bool
isPrefixOfStr [] _ = True
isPrefixOfStr _ [] = False
isPrefixOfStr (x : xs) (y : ys) = x == y && isPrefixOfStr xs ys

isInfixOfStr :: String -> String -> Bool
isInfixOfStr needle haystack
  | needle `isPrefixOfStr` haystack = True
  | null haystack = False
  | otherwise = isInfixOfStr needle (tail haystack)
