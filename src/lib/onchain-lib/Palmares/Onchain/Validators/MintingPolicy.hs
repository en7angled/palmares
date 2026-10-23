
-- Required for `makeLift`:
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:conservative-optimisation #-}

{-# HLINT ignore "Use &&" #-}

-- | Minting policy for the Palmares attestation protocol.
-- Controls token creation for profiles and attestations.
module Palmares.Onchain.Validators.MintingPolicy
  ( -- * Minting Redeemer
    MintingRedeemer (..),

    -- * Minting Policy
    mintingPolicyLambda,

    -- * Compilation
    mintingPolicyCompile,
  )
where

import GHC.Generics (Generic)
import Palmares.Onchain.CIP68
  ( MetadataFields,
    deriveUserFromRefAC,
    generateRefAndUserTN,
    isProtocolRefToken,
    mkCIP68Datum,
    validateMetadataFields,
    validateOtherMetadata,
  )
import Palmares.Onchain.Protocol.Lookup (checkFee, readOracleParams)
import Palmares.Onchain.Protocol.Types
  ( AttestationId,
    AttestationKind (CredentialClaim, CredentialWithdrawal),
    ClaimedCredential,
    claimedCredentialOf,
    MintAction (MintActionAttestation, MintActionDispute, MintActionProfile),
    OnchainAttestation
      ( OnchainAttestation,
        attestationIssuer,
        attestationSubject,
        attestationDate,
        attestationId,
        attestationCredential,
        attestationIsAccepted,
        attestationKind,
        attestationOracleToken,
        attestationPeriod
      ),
    OnchainProfile
      ( OnchainProfile,
        profileId,
        profileKind,
        profileOracleToken
      ),
    OnchainDispute
      ( OnchainDispute,
        disputeDeposit,
        disputeDepositTo,
        disputeId,
        disputeOpenedAt,
        disputeOpenedBy,
        disputeOracleToken,
        disputeStaleAfter,
        disputeTarget,
        disputeVerdict
      ),
    OnchainProfileKind,
    OracleParams (opDisputeDeposit, opDisputeTimeoutMs, opMinUTxOValue, opPaused),
    ProfileId,
    ProtocolParams
      ( attestationsValidatorScriptHash,
        disputesValidatorScriptHash,
        oracleToken,
        profilesValidatorScriptHash
      ),
  )
import Palmares.Onchain.Utils qualified as Utils
  ( checkCredentialControl,
    checkDateInRange,
    checkTxOutAtIndexWithDatumMinValueAndAddress,
    inputsSpendTxOutRef,
    mkUntypedLambda,
    nameFromTxOutRef,
    valueAtOutputIdx,
  )
import PlutusCore.Builtin.Debug (plcVersion110)
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V3
import PlutusLedgerApi.V3.Contexts
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude
import Prelude qualified

-------------------------------------------------------------------------------

-- * Minting Redeemer

-------------------------------------------------------------------------------

-- | Custom redeemer :
-- Output indices are passed in the redeemer for efficient O(1) lookup instead of O(n) search.
data MintingRedeemer
  = -- | NewAttestation seedTxOutRef metadata222 otherMetadata subject issuer kind attestationDate claimedPeriod claimedCredential attestationOutputIdx
    --
    -- @kind@ and @claimedPeriod@ are the two the spec's §3 glossary required and the first cut
    -- omitted. @claimedPeriod@ is self-reported and carries NO check — see 'attestationPeriod'.
    --
    -- @claimedCredential@ arrived with __ADR 0003__ and is the opposite of self-reported: it is
    -- 'Just' exactly for the two credential kinds, where @Mc3@ requires the credential to prove
    -- control of this transaction, and 'Nothing' for the other five, where @Mc4@ requires its
    -- absence. It used to be an argument of @MintProfile@, checked by @Mp3@, in a field on the
    -- profile datum that a destructive redeemer could clear.
    NewAttestation TxOutRef MetadataFields [(BuiltinByteString, BuiltinByteString)] ProfileId ProfileId AttestationKind POSIXTime (Maybe (POSIXTime, POSIXTime)) (Maybe ClaimedCredential) Integer
  | -- | MintProfile seedTxOutRef kind metadata profileOutputIdx
    --
    -- __No credential argument — ADR 0003.__ Minting a profile no longer claims anything; a claim is
    -- a 'CredentialClaim' attestation, which costs a second transaction and buys an append-only
    -- record that no redeemer can erase. The argument that used to sit here is now
    -- @NewAttestation@'s.
    MintProfile TxOutRef OnchainProfileKind MetadataFields Integer
  | -- | OpenDispute seedTxOutRef target openedBy depositTo metadata openedAt disputeOutputIdx
    --
    -- @depositTo@ is where the deposit returns on either verdict, named by the disputer here because
    -- the Disputes Validator cannot resolve a 'ProfileId' into an address. It must be an address
    -- this transaction spends from (@Md8@).
    --
    -- This used to end "pointing it somewhere useless costs only the disputer", and that was wrong:
    -- resolution pays with @txOutAddress == disputeDepositTo@, so an address no real output can
    -- carry made @D4@ UNSATISFIABLE and the dispute permanently unresolvable — a five-ADA
    -- permanent accusation on the SUBJECT's record, which is whose cost it was.
    OpenDispute TxOutRef AttestationId ProfileId Address MetadataFields POSIXTime Integer
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (HasBlueprintDefinition)

-- The stable-index discipline binds from the first deployment. Nothing is deployed yet, so the
-- surviving redeemer takes index 0 rather than keeping its Belt System index and reserving holes;
-- MintProfile is APPENDED at 1 rather than inserted, which is the discipline from here on.
makeIsDataSchemaIndexed ''MintingRedeemer [('NewAttestation, 0), ('MintProfile, 1), ('OpenDispute, 2)]

-------------------------------------------------------------------------------

-- | Precomputed minLv and validator addresses for the minting policy.
data MintingContext = MintingContext
  { ctxMinLv :: Value,
    ctxProfilesAddress :: Address,
    ctxAttestationsAddress :: Address,
    ctxDisputesAddress :: Address,
    -- | The deposit a NEW dispute must lock, read from the oracle at open time and then recorded in
    -- the dispute's own datum. After that the oracle's current price is irrelevant to it.
    ctxDisputeDeposit :: Integer,
    -- | The oracle's own token, copied from this policy's compile-time parameter into every
    -- attestation datum so that @AcceptAttestation@ can find the oracle. See
    -- 'Palmares.Onchain.Protocol.Types.attestationOracleToken'.
    ctxOracleToken :: V1.AssetClass,
    -- | How long a NEW dispute may sit undecided, read from the oracle at open time and then
    -- recorded in the dispute's own datum as an absolute moment. See
    -- 'Palmares.Onchain.Protocol.Types.disputeStaleAfter'.
    ctxDisputeTimeoutMs :: Integer
  }

-------------------------------------------------------------------------------

-- * Minting Policy

-------------------------------------------------------------------------------

{-# INLINEABLE mintingPolicyLambda #-}
mintingPolicyLambda :: ProtocolParams -> ScriptContext -> Bool
mintingPolicyLambda protocolParams (ScriptContext txInfo@TxInfo {..} (Redeemer bredeemer) scriptInfo) =
  let !redeemer = unsafeFromBuiltinData @MintingRedeemer bredeemer
   in case scriptInfo of
        (MintingScript mintingPolicyCurrencySymbol) ->
          let oracle = readOracleParams (oracleToken protocolParams) txInfoReferenceInputs
              !minLv = V1.lovelaceValue (V1.Lovelace (opMinUTxOValue oracle))
              !profilesValidatorAddress = V1.scriptHashAddress (profilesValidatorScriptHash protocolParams)
              !attestationsValidatorAddress = V1.scriptHashAddress (attestationsValidatorScriptHash protocolParams)
              !disputesValidatorAddress = V1.scriptHashAddress (disputesValidatorScriptHash protocolParams)
              ctx =
                MintingContext
                  { ctxMinLv = minLv,
                    ctxProfilesAddress = profilesValidatorAddress,
                    ctxAttestationsAddress = attestationsValidatorAddress,
                    ctxDisputesAddress = disputesValidatorAddress,
                    ctxDisputeDeposit = opDisputeDeposit oracle,
                    ctxOracleToken = oracleToken protocolParams,
                    ctxDisputeTimeoutMs = opDisputeTimeoutMs oracle
                  }
           in -- Global gate: protocol must not be paused (M0).
              traceIfFalse "M0" (not (opPaused oracle)) -- Protocol is paused (M0)
                && case redeemer of
                  NewAttestation seedTxOutRef metadata otherMetadata subject issuer kind attestationDate claimedPeriod claimedCredential attestationOutputIdx ->
                    checkFee oracle MintActionAttestation txInfoOutputs
                      && handleNewAttestation txInfo mintingPolicyCurrencySymbol ctx seedTxOutRef metadata otherMetadata subject issuer kind attestationDate claimedPeriod claimedCredential attestationOutputIdx
                  MintProfile seedTxOutRef kind metadata profileOutputIdx ->
                    checkFee oracle MintActionProfile txInfoOutputs
                      && handleMintProfile txInfo mintingPolicyCurrencySymbol protocolParams ctx seedTxOutRef kind metadata profileOutputIdx
                  OpenDispute seedTxOutRef target openedBy depositTo metadata openedAt disputeOutputIdx ->
                    checkFee oracle MintActionDispute txInfoOutputs
                      && handleOpenDispute txInfo mintingPolicyCurrencySymbol protocolParams ctx seedTxOutRef target openedBy depositTo metadata openedAt disputeOutputIdx
        _ -> traceError "M1" -- Invalid purpose (M1)

-------------------------------------------------------------------------------

-- * Per-Redeemer Handlers

-------------------------------------------------------------------------------

{-# INLINEABLE handleNewAttestation #-}
handleNewAttestation ::
  TxInfo ->
  CurrencySymbol ->
  MintingContext ->
  TxOutRef ->
  MetadataFields ->
  [(BuiltinByteString, BuiltinByteString)] ->
  ProfileId ->
  ProfileId ->
  AttestationKind ->
  POSIXTime ->
  Maybe (POSIXTime, POSIXTime) ->
  Maybe ClaimedCredential ->
  Integer ->
  Bool
handleNewAttestation txInfo@TxInfo {..} mintingPolicyCurrencySymbol ctx seedTxOutRef metadata otherMetadataEncoded subject issuer kind attestationDate claimedPeriod claimedCredential attestationOutputIdx =
  let isSubjectValid = isProtocolRefToken subject mintingPolicyCurrencySymbol
      isIssuerValid = isProtocolRefToken issuer mintingPolicyCurrencySymbol
      minLv = ctxMinLv ctx
      attestationsValidatorAddress = ctxAttestationsAddress ctx

      (attestationRefTN, _) = generateRefAndUserTN (Utils.nameFromTxOutRef seedTxOutRef)
      attestationRefAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, attestationRefTN)
      attestationNFT = V1.assetClassValue attestationRefAssetClass 1
      attestationValue = (attestationNFT + minLv)
      attestationInfo =
        OnchainAttestation
          { attestationId = attestationRefAssetClass,
            attestationSubject = subject,
            attestationIssuer = issuer,
            attestationKind = kind,
            attestationDate = attestationDate,
            -- Carried through unchecked, on purpose. `Mk` below compares this whole datum against
            -- the output, so the period the issuer put in the redeemer is the period that lands in
            -- the record — and that is the entire guarantee, because the claim is the issuer's and
            -- the chain cannot confirm it. The subject's counter-signature is what makes it a
            -- record. A `from <= to` check here would be ExUnits on every issue for a nonsense the
            -- subject would have to accept about itself, which is the trade this repo rejects by
            -- standing rule; `issueAttestationTX` refuses it as a 400 instead.
            attestationPeriod = claimedPeriod,
            attestationIsAccepted = False,
            -- The parameter, not anything the client chose — the same line 'handleOpenDispute'
            -- writes for `disputeOracleToken`, and the reason a datum cannot name a forged oracle.
            attestationOracleToken = ctxOracleToken ctx,
            -- Carried through from the redeemer, and `Mk` compares this whole datum against the
            -- output — so what the four rules below establish about it is what the record says
            -- forever. ADR 0003.
            attestationCredential = claimedCredential
          }

      attestationDatum = mkCIP68Datum attestationInfo metadata otherMetadataEncoded

      -- ADR 0003's three predicates. Pattern matches rather than an `Eq AttestationKind` instance:
      -- PlutusTx has no deriving for that class, and a two-way match is cheaper than writing one.
      isCredentialKind = case kind of
        CredentialClaim -> True
        CredentialWithdrawal -> True
        _ -> False
      isWithdrawalKind = case kind of
        CredentialWithdrawal -> True
        _ -> False
      credentialIsNamed = case claimedCredential of
        Just _ -> True
        Nothing -> False
      -- The same rule @Mp3@ was, moved to the record whose whole purpose is the binding. Its
      -- documented limit carries over: a script that ONLY ever votes or withdraws holds no UTxO at
      -- its own address, so it sends itself one first.
      -- The INNER credential (ADR 0006): the role is for the record and the renderer, and all three
      -- roles are asked the same question. Unwrapping here rather than per role keeps that single.
      credentialConsents = case claimedCredential of
        Nothing -> False
        Just claimed -> Utils.checkCredentialControl (claimedCredentialOf claimed) txInfoSignatories txInfoInputs
   in -- RENAMED FROM `Ml` on 2026-10-22, and the reason is the terminal: a lowercase L is
      -- indistinguishable from a digit 1 in most monospace fonts, and `M1` is a different code on
      -- the same script ("invalid purpose"). An operator reading a failed transaction's log would
      -- have debugged the wrong rule. This code sequence already skips `i` for exactly that reason
      -- — f, g, h, j, k, m, n — so `l` was the one letter that undid its own convention; `o` is
      -- skipped on the same grounds.
      traceIfFalse "Mq" (Utils.checkDateInRange attestationDate txInfoValidRange) -- Attestation date not inside validity interval (Mq)
        && traceIfFalse "Mm" (validateMetadataFields metadata) -- Metadata fields validation failed (Mm)
        && traceIfFalse "Mn" (validateOtherMetadata otherMetadataEncoded) -- otherMetadata too big, or duplicate keys (Mn)
        -- @Mf@ IS CONDITIONAL, and 'CredentialWithdrawal' is the one exemption — ADR 0003.
        --
        -- For every other kind, spending the issuer's user NFT is what makes @attestationIssuer@
        -- mean "this profile said so". A withdrawal is the one record where the profile must NOT be
        -- asked: the case it exists for is a profile that claimed somebody else's credential, and
        -- that profile's token is held by whoever did it. Requiring it would hand the remedy to the
        -- only party that must not have it — the exact defect an audit found in the D-E revocation
        -- this replaces.
        --
        -- So on the two credential kinds @attestationIssuer@ is STRUCTURAL: @Mc1@ forces it to equal
        -- the subject, so it names the profile the record is about and makes no claim about who
        -- acted. Who acted is @Mc3@'s statement, and on a claim it is both parties — @Mf@ for the
        -- profile, @Mc3@ for the credential.
        && traceIfFalse "Mf" (isWithdrawalKind || V1.assetClassValueOf (valueSpent txInfo) (deriveUserFromRefAC issuer) == 1) -- Must spend issued by user NFT (Mf)
        && traceIfFalse "Mg" (isSubjectValid && isIssuerValid) -- Profile ids must be this protocol's REF tokens (Mg)
        -- ADR 0003. A binding is an attestation, so these four rules are what keep that record
        -- honest — and what keep the credential field off the five kinds where nothing checks it.
        && traceIfFalse "Mc1" (not isCredentialKind || subject == issuer) -- A credential record is self-issued (Mc1)
        && traceIfFalse "Mc2" (not isCredentialKind || credentialIsNamed) -- A credential record must name a credential (Mc2)
        && traceIfFalse "Mc3" (not isCredentialKind || credentialConsents) -- Named credential does not control this tx (Mc3)
        && traceIfFalse "Mc4" (isCredentialKind || not credentialIsNamed) -- Only a credential record may name one (Mc4)
        && traceIfFalse "Mh" (Utils.inputsSpendTxOutRef seedTxOutRef txInfoInputs) -- Must spend seed for uniqueness (Mh)
        && traceIfFalse
          "Mj" -- Tx must mint JUST attestation NFT (Mj)
          (mintValueMinted txInfoMint == attestationNFT && mintValueBurned txInfoMint == mempty)
        && traceIfFalse "Mk" (Utils.checkTxOutAtIndexWithDatumMinValueAndAddress attestationOutputIdx attestationDatum attestationValue attestationsValidatorAddress txInfoOutputs) -- Lock attestation at AttestationsValidator address (Mk)
        -- `Mp6`'s rule, on this path — OC-03. `Mk` accepts an output carrying AT LEAST the expected
        -- value, so the issuer's own user token could be parked inside the attestation it issues.
        -- Nothing ever burns an attestation, so the token would be gone for good and the issuer's
        -- identity would lose the authority instrument this protocol runs on.
        --
        -- A WITHDRAWAL IS NOT EXEMPT, unlike under `Mf`. `Mf` exempts it because a withdrawal proves
        -- control by the credential alone and spends no user token; this rule is about what the
        -- OUTPUT holds, and a withdrawal has no more business locking a token away than a claim does.
        && traceIfFalse "Ms" (V1.assetClassValueOf (Utils.valueAtOutputIdx attestationOutputIdx txInfoOutputs) (deriveUserFromRefAC issuer) == 0) -- Issuer's user token must not be locked with the state (Ms)

{-# INLINEABLE handleMintProfile #-}
handleMintProfile ::
  TxInfo ->
  CurrencySymbol ->
  ProtocolParams ->
  MintingContext ->
  TxOutRef ->
  OnchainProfileKind ->
  MetadataFields ->
  Integer ->
  Bool
handleMintProfile TxInfo {..} mintingPolicyCurrencySymbol protocolParams ctx seedTxOutRef kind metadata profileOutputIdx =
  let minLv = ctxMinLv ctx
      profilesValidatorAddress = ctxProfilesAddress ctx

      (profileRefTN, profileUserTN) = generateRefAndUserTN (Utils.nameFromTxOutRef seedTxOutRef)
      profileRefAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, profileRefTN)
      profileUserAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, profileUserTN)
      profileRefNFT = V1.assetClassValue profileRefAssetClass 1
      profileUserNFT = V1.assetClassValue profileUserAssetClass 1
      profileValue = profileRefNFT + minLv

      profileInfo =
        OnchainProfile
          { profileId = profileRefAssetClass,
            profileKind = kind,
            profileOracleToken = oracleToken protocolParams
          }
      profileDatum = mkCIP68Datum profileInfo metadata []
   in traceIfFalse "Mp1" (Utils.inputsSpendTxOutRef seedTxOutRef txInfoInputs) -- Must spend seed for uniqueness (Mp1)
        && traceIfFalse
          "Mp2" -- Tx must mint JUST the profile ref AND user NFT (Mp2)
          (mintValueMinted txInfoMint == (profileRefNFT + profileUserNFT) && mintValueBurned txInfoMint == mempty)
        -- @Mp3@ IS GONE, and its index is not reused: it required a claimed credential to control
        -- this transaction, and ADR 0003 moved the claim out of this path entirely. The rule it
        -- became is @Mc3@, on the 'CredentialClaim' attestation, where the transaction's whole
        -- visible purpose is the binding — so a signature on it is far harder to misrepresent than
        -- one on a profile mint that happened to carry a credential.
        && traceIfFalse "Mp4" (validateMetadataFields metadata) -- Metadata fields validation failed (Mp4)
        && traceIfFalse "Mp5" (Utils.checkTxOutAtIndexWithDatumMinValueAndAddress profileOutputIdx profileDatum profileValue profilesValidatorAddress txInfoOutputs) -- Lock profile at ProfilesValidator address (Mp5)
        -- THE USER TOKEN MUST NOT END UP IN THE STATE OUTPUT, and @Mp5@ positively permits it
        -- because it uses `geq`: a value of ref + user + minLv satisfies `geq (ref + minLv)` and
        -- the datum is byte-identical, so the whole mint validated with the authority token locked
        -- beside the state it authorises.
        --
        -- What that bought an attacker: @P3@ asks for quantity 1 of the profile's user token in
        -- `valueSpent`, so the profile's OWN input satisfied it. Every stranger then passed
        -- @P2@/@P3@/@P4@/@P5@/@P6@ and could rewrite that profile's description and image for ever,
        -- and by spending it in the same transaction satisfied @Mf@ and issued attestations AS that
        -- profile. A permanently world-writable identity.
        --
        -- The invariant existed only in off-chain prose — @Operations.hs@: "The user token is not
        -- paid anywhere explicitly, so it lands in the balancer's change output — in the claimant's
        -- wallet, which is where authority belongs." That is a statement about the builder, and a
        -- hand-built transaction is not the builder.
        --
        -- The paragraph that used to end here described what @Mp3@ did NOT close: a transaction the
        -- victim co-signs for an unrelated reason minting a profile that claims the victim's
        -- credential while the attacker keeps the authority token. ADR 0003 answered it by moving
        -- the claim to its own append-only record, so a profile mint now claims nothing and there is
        -- no binding here to misdirect.
        && traceIfFalse "Mp6" (V1.assetClassValueOf (Utils.valueAtOutputIdx profileOutputIdx txInfoOutputs) profileUserAssetClass == 0) -- User token must not be locked with the state (Mp6)

-- | Open a dispute against an attestation: lock the deposit, record what was paid, prove who paid it.
--
-- __Nothing here touches the attestation being disputed.__ It is not spent, not re-datumed, not even
-- read as an input — only its asset class is checked for the protocol's currency symbol. That is what
-- makes a dispute openable without the subject's or the issuer's cooperation, and what keeps the
-- attestation path's ExUnits unchanged.
--
-- __Only the ref token is minted, no user token.__ A user token is authority to do something, and
-- there is nothing a dispute's holder may do: resolution is the oracle admin's, and the deposit
-- returns to an address fixed in the datum. Minting one would be minting an authority with no powers,
-- which later reads as a capability someone can look for.
--
-- __Two checks the plan's sketch of this handler omitted__, both standing requirements rather than
-- additions: @Md6@ bounds @openedAt@ to the transaction's validity interval, which
-- `onchain-lib/CLAUDE.md` requires of every date stored in a datum (inherited fix #4), and @Md7@
-- validates the metadata sizes exactly as the other two mint paths do.
--
-- __@openedBy@ had no currency-symbol check, and that made @Md3@ self-issued.__ @Md4@ checked only
-- @target@; the sibling handler's @Mg@ has always checked both of its 'ProfileId's. @Md3@ proves the
-- opener by requiring the transaction to spend the user NFT derived from @openedBy@ — but an
-- 'AssetClass' with an attacker-chosen currency symbol derives a token under the attacker's OWN
-- policy, which they mint beforehand and spend here. So anyone could open a dispute while owning no
-- profile in this protocol, and the dispute would be recorded as opened by a profile id that does not
-- exist. @Md4@ now covers both, exactly as @Mg@ does.
--
-- __@depositTo@ entered a permanent datum unvalidated, and an unsatisfiable @D4@ is a locked UTxO.__
-- The address is redeemer data that nothing checked, and resolution pays the deposit with
-- @txOutAddress == disputeDepositTo@. An address no real output can carry — @PubKeyCredential
-- (PubKeyHash \"\")@ is representable in Plutus data and not in a ledger address — makes @D4@
-- unsatisfiable, so the oracle admin CANNOT resolve the dispute, ever. The dispute's NFT and deposit
-- stay locked and the dispute stays open against the target attestation forever, which is the attack:
-- five ADA buys a permanent, unresolvable accusation on somebody else's record. @Md8@ requires the
-- address to be one this transaction spends from, which is the cheapest proof that it is a real
-- address somebody controls — they just controlled it.
--
-- @Md8@ rather than extending @Md5@: \"the dispute output is wrong\" and \"the payout address is not
-- real\" are different mistakes, and the same argument the attestation path makes for @A3@ over @A1@.
{-# INLINEABLE handleOpenDispute #-}
handleOpenDispute ::
  TxInfo ->
  CurrencySymbol ->
  ProtocolParams ->
  MintingContext ->
  TxOutRef ->
  AttestationId ->
  ProfileId ->
  Address ->
  MetadataFields ->
  POSIXTime ->
  Integer ->
  Bool
handleOpenDispute txInfo@TxInfo {..} mintingPolicyCurrencySymbol protocolParams ctx seedTxOutRef target openedBy depositTo metadata openedAt disputeOutputIdx =
  let minLv = ctxMinLv ctx
      deposit = ctxDisputeDeposit ctx
      disputesValidatorAddress = ctxDisputesAddress ctx

      (disputeRefTN, _) = generateRefAndUserTN (Utils.nameFromTxOutRef seedTxOutRef)
      disputeRefAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, disputeRefTN)
      disputeNFT = V1.assetClassValue disputeRefAssetClass 1
      -- The deposit is part of the locked value, which is the whole economic mechanism: it sits in
      -- the dispute's own UTxO until a verdict releases it, so N disputes cost N deposits and no
      -- index UTxO is needed to bound them.
      disputeValue = disputeNFT + minLv + V1.lovelaceValue (V1.Lovelace deposit)

      disputeInfo =
        OnchainDispute
          { disputeId = disputeRefAssetClass,
            disputeTarget = target,
            disputeOpenedBy = openedBy,
            disputeOpenedAt = openedAt,
            -- Recorded, not referenced. See 'Palmares.Onchain.Protocol.Types.opDisputeDeposit'.
            disputeDeposit = deposit,
            disputeDepositTo = depositTo,
            disputeOracleToken = oracleToken protocolParams,
            -- Recorded, not referenced, for the same reason the deposit above is: read from the
            -- oracle at CLOSING time, an admin could raise the timeout and postpone every open
            -- dispute's deadline — and an admin who does not act is the failure D-A bounds.
            disputeStaleAfter = openedAt + POSIXTime (ctxDisputeTimeoutMs ctx),
            disputeVerdict = Nothing
          }
      disputeDatum = mkCIP68Datum disputeInfo metadata []
   in traceIfFalse "Md1" (Utils.inputsSpendTxOutRef seedTxOutRef txInfoInputs) -- Must spend seed for uniqueness (Md1)
        && traceIfFalse
          "Md2" -- Tx must mint JUST the dispute ref NFT (Md2)
          (mintValueMinted txInfoMint == disputeNFT && mintValueBurned txInfoMint == mempty)
        && traceIfFalse "Md3" (V1.assetClassValueOf (valueSpent txInfo) (deriveUserFromRefAC openedBy) == 1) -- Must spend the disputer's user NFT (Md3)
        && traceIfFalse "Md4" (isProtocolRefToken target mintingPolicyCurrencySymbol && isProtocolRefToken openedBy mintingPolicyCurrencySymbol) -- Target and opener must be this protocol's REF tokens (Md4)
        && traceIfFalse "Md8" (any ((== depositTo) . txOutAddress . txInInfoResolved) txInfoInputs) -- Deposit address must be spent from by this tx (Md8)
        && traceIfFalse "Md5" (Utils.checkTxOutAtIndexWithDatumMinValueAndAddress disputeOutputIdx disputeDatum disputeValue disputesValidatorAddress txInfoOutputs) -- Lock dispute + deposit at DisputesValidator address (Md5)
        -- `Mp6`'s rule, on this path — OC-03. The dispute output already holds the deposit, so `Md5`
        -- is a @>=@ check with room in it: the opener's user token could ride along and never come
        -- back, because resolution returns the deposit and re-locks the dispute, and nothing burns a
        -- dispute. Opening one dispute would cost the opener their identity's authority.
        && traceIfFalse "Md9" (V1.assetClassValueOf (Utils.valueAtOutputIdx disputeOutputIdx txInfoOutputs) (deriveUserFromRefAC openedBy) == 0) -- Opener's user token must not be locked with the dispute (Md9)
        && traceIfFalse "Md6" (Utils.checkDateInRange openedAt txInfoValidRange) -- Open date not inside validity interval (Md6)
        && traceIfFalse "Md7" (validateMetadataFields metadata) -- Metadata fields validation failed (Md7)

-------------------------------------------------------------------------------

-- * Compilation

-------------------------------------------------------------------------------

-- | Lose the types
{-# INLINEABLE mintingPolicyUntyped #-}
mintingPolicyUntyped :: ProtocolParams -> BuiltinData -> BuiltinUnit
mintingPolicyUntyped params =
  Utils.mkUntypedLambda (mintingPolicyLambda params)

-- | Compile the untyped lambda to a UPLC script and splice back to Haskell.
mintingPolicyCompile :: ProtocolParams -> CompiledCode (BuiltinData -> BuiltinUnit)
mintingPolicyCompile params = $$(compile [||mintingPolicyUntyped||]) `unsafeApplyCode` liftCode plcVersion110 params
