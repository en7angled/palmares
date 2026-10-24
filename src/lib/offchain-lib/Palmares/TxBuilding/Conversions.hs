-- | Bidirectional conversions between on-chain Plutus types and off-chain domain types.
module Palmares.TxBuilding.Conversions where

import Data.Bifunctor qualified
import Data.ByteString.Base16 qualified as B16
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Ids (GovCredentialRole (..), parseCredentialRoleCip129, renderCredentialRoleCip129)
import Palmares.DomainTypes.Core.Types
import Palmares.DomainTypes.Transfer.Types (CredentialRef (..), OracleParamsResponse (..))
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.Onchain.CIP68 (CIP68Datum (..), MetadataFields (..), extra, getMetadataFields)
import Palmares.Onchain.Protocol qualified as Onchain
import Palmares.Onchain.Protocol.Lookup qualified as Lookup
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import PlutusLedgerApi.V3 hiding (Committee) -- ours is a profile kind; Plutus's is the CIP-1694 committee datum
import PlutusTx.AssocMap qualified as AssocMap
import PlutusTx.Builtins.HasOpaque (stringToBuiltinByteStringUtf8)

-- | Convert domain 'ProfileData' to on-chain CIP-68 metadata fields.
profileDataToMetadataFields :: ProfileData -> MetadataFields
profileDataToMetadataFields ProfileData {profileDataName, profileDataDescription, profileDataImageURI} =
  Metadata222
    { metadataName = textToBuiltinByteString profileDataName,
      metadataDescription = textToBuiltinByteString profileDataDescription,
      metadataImageURI = textToBuiltinByteString profileDataImageURI
    }

-- | Convert on-chain CIP-68 metadata fields to domain 'ProfileData'.
metadataFieldsToProfileData :: MetadataFields -> ProfileData
metadataFieldsToProfileData Metadata222 {metadataName, metadataDescription, metadataImageURI} =
  ProfileData
    { profileDataName = fromBuiltinByteStringUtf8 metadataName,
      profileDataDescription = fromBuiltinByteStringUtf8 metadataDescription,
      profileDataImageURI = fromBuiltinByteStringUtf8 metadataImageURI
    }

textToBuiltinByteString :: T.Text -> BuiltinByteString
textToBuiltinByteString = stringToBuiltinByteStringUtf8 . T.unpack

-- | Decode an on-chain UTF-8 'BuiltinByteString' to 'Text', replacing any
-- invalid byte sequence with U+FFFD (never throws — keeps chain-sync alive on
-- malformed metadata).
fromBuiltinByteStringUtf8 :: BuiltinByteString -> T.Text
fromBuiltinByteStringUtf8 = TE.decodeUtf8With TEE.lenientDecode . fromBuiltin

-- | Map domain 'ProfileType' to its on-chain representation.
--
-- Written out arm by arm rather than through 'fromEnum', deliberately: the two enums agree in order
-- today and a coincidence of order is not a thing to rely on across a layer boundary. Both directions
-- are total, so @-Wincomplete-patterns@ is what catches a seventh kind added on one side only.
profileTypeToOnchainProfileKind :: ProfileType -> Onchain.OnchainProfileKind
profileTypeToOnchainProfileKind PersonDRep = Onchain.PersonDRep
profileTypeToOnchainProfileKind Organization = Onchain.Organization
profileTypeToOnchainProfileKind Committee = Onchain.Committee
profileTypeToOnchainProfileKind Community = Onchain.Community
profileTypeToOnchainProfileKind Vendor = Onchain.Vendor
profileTypeToOnchainProfileKind Auditor = Onchain.Auditor

-- | Map an on-chain profile kind to the domain 'ProfileType'.
onchainProfileKindToProfileType :: Onchain.OnchainProfileKind -> ProfileType
onchainProfileKindToProfileType Onchain.PersonDRep = PersonDRep
onchainProfileKindToProfileType Onchain.Organization = Organization
onchainProfileKindToProfileType Onchain.Committee = Committee
onchainProfileKindToProfileType Onchain.Community = Community
onchainProfileKindToProfileType Onchain.Vendor = Vendor
onchainProfileKindToProfileType Onchain.Auditor = Auditor

-- | Map domain 'AttestationType' to its on-chain representation.
--
-- Arm by arm for the same reason 'profileTypeToOnchainProfileKind' is: agreeing in order today is a
-- coincidence, not a contract, and @-Wincomplete-patterns@ is what catches a sixth kind added on one
-- side only.
attestationTypeToOnchainAttestationKind :: AttestationType -> Onchain.AttestationKind
attestationTypeToOnchainAttestationKind MilestoneDelivered = Onchain.MilestoneDelivered
attestationTypeToOnchainAttestationKind AuditPassed = Onchain.AuditPassed
attestationTypeToOnchainAttestationKind Affiliation = Onchain.Affiliation
attestationTypeToOnchainAttestationKind RoleHeld = Onchain.RoleHeld
attestationTypeToOnchainAttestationKind Endorsement = Onchain.Endorsement
attestationTypeToOnchainAttestationKind CredentialClaim = Onchain.CredentialClaim
attestationTypeToOnchainAttestationKind CredentialWithdrawal = Onchain.CredentialWithdrawal

-- | Map an on-chain attestation kind to the domain 'AttestationType'.
onchainAttestationKindToAttestationType :: Onchain.AttestationKind -> AttestationType
onchainAttestationKindToAttestationType Onchain.MilestoneDelivered = MilestoneDelivered
onchainAttestationKindToAttestationType Onchain.AuditPassed = AuditPassed
onchainAttestationKindToAttestationType Onchain.Affiliation = Affiliation
onchainAttestationKindToAttestationType Onchain.RoleHeld = RoleHeld
onchainAttestationKindToAttestationType Onchain.Endorsement = Endorsement
onchainAttestationKindToAttestationType Onchain.CredentialClaim = CredentialClaim
onchainAttestationKindToAttestationType Onchain.CredentialWithdrawal = CredentialWithdrawal

------------------------------------------------------------------------------------------------

-- * The claim: credential and witness

------------------------------------------------------------------------------------------------

-- | The credential a profile claims, from the CIP-129 identifier a client sent.
--
-- __The header byte is the whole point.__ CIP-129 carries it, and it is what says whether these 28
-- bytes are a key hash or a script hash — which decides which arm of the claim rule applies
-- ('Palmares.Onchain.Utils.checkCredentialControl'). A CIP-105 id or a bare hex hash is therefore
-- refused rather than guessed at: @drep@ is the HRP for both kinds, so defaulting to the key arm
-- would silently mis-claim every script DRep.
--
-- Pure, and refused before any chain query, so a client that pasted a broken identifier gets a 400
-- rather than a timeout.
parseClaimCredential :: T.Text -> Either TxBuildingException OnchainTypes.ClaimedCredential
parseClaimCredential t = case parseCredentialRoleCip129 t of
  Just (role, isScript, raw) -> Right (wrap role (credentialOf isScript raw))
  Nothing -> Left CredentialMalformed
  where
    credentialOf True raw = ScriptCredential (ScriptHash (toBuiltin raw))
    credentialOf False raw = PubKeyCredential (PubKeyHash (toBuiltin raw))
    wrap RoleDRep = OnchainTypes.ClaimedDRep
    wrap RoleCCCold = OnchainTypes.ClaimedCCCold
    wrap RoleCCHot = OnchainTypes.ClaimedCCHot

-- | The CIP-129 rendering of a claimed credential — the inverse of 'parseClaimCredential'.
--
-- __The HRP now follows the claimed ROLE__ (ADR 0006), which is the fix for @OC-04@. Before, every
-- claim was rendered with @drep@, on the argument that "which governance role those bytes play is
-- the profile's @kind@, not part of the credential". That argument was wrong twice: @profileKind@ is
-- not a role — an @Organization@ may be a DRep and a @Committee@ may hold both committee
-- credentials — and the datum now stores the role, so nothing has to be inferred. A committee cold
-- credential claimed as @cc_cold1…@ used to read back as @drep1…@ of the same bytes: an identifier
-- that resolves to nothing in GovTool or db-sync, so a reader could not verify what they were shown.
claimCredentialToText :: OnchainTypes.ClaimedCredential -> T.Text
claimCredentialToText claimed = renderCredentialRoleCip129 (roleOf claimed) isScript raw
  where
    (isScript, raw) = case OnchainTypes.claimedCredentialOf claimed of
      ScriptCredential (ScriptHash bs) -> (True, fromBuiltin bs)
      PubKeyCredential (PubKeyHash bs) -> (False, fromBuiltin bs)
    roleOf (OnchainTypes.ClaimedDRep _) = RoleDRep
    roleOf (OnchainTypes.ClaimedCCCold _) = RoleCCCold
    roleOf (OnchainTypes.ClaimedCCHot _) = RoleCCHot

-- | Is this credential a script rather than a key? The two take different proofs of control.
isScriptCredential :: Credential -> Bool
isScriptCredential (ScriptCredential _) = True
isScriptCredential (PubKeyCredential _) = False

-- | A 'Credential' as the read surface publishes it — 28 bytes of hex plus which kind it is.
credentialRef :: Credential -> CredentialRef
credentialRef c = CredentialRef (hexOf c) (isScriptCredential c)
  where
    hexOf (PubKeyCredential (PubKeyHash bs)) = TE.decodeUtf8 (B16.encode (fromBuiltin bs))
    hexOf (ScriptCredential (ScriptHash bs)) = TE.decodeUtf8 (B16.encode (fromBuiltin bs))

-- | The oracle datum as @interaction-api@'s @\/status@ publishes it.
--
-- Here rather than in the service because this is the only layer that has both sides: the Plutus
-- types are on-chain and the DTO is a transfer type, and a service that converted between them
-- directly would be the second place in the tree that knows how a 'Credential' is rendered.
--
-- Total over the record on purpose: a new oracle parameter has to be named here before it can be
-- published, which is the opposite of the failure that put @opDisputeTimeoutMs@ in the datum and
-- nowhere else for a month.
oracleParamsResponse :: OnchainTypes.OracleParams -> OracleParamsResponse
oracleParamsResponse p =
  OracleParamsResponse
    { oracleDisputeDepositLovelace = OnchainTypes.opDisputeDeposit p,
      oracleDisputeTimeoutMs = OnchainTypes.opDisputeTimeoutMs p,
      oracleMinUtxoLovelace = OnchainTypes.opMinUTxOValue p,
      oracleArbiter = credentialRef (OnchainTypes.opArbiter p),
      oracleAdmin = credentialRef (OnchainTypes.opAdmin p),
      -- Through `feeFor` and NOT by selecting the two fields, for the reason `check_vocabulary.sh`
      -- enforces: a `FeeConfig` field is named where the record is defined and in `feeFor`, and
      -- nowhere else, because a second naming site is how the Belt System's interval fee came to
      -- charge the wrong field. It is also the better number — the published figure is produced by
      -- the same total function that decides what a mint is charged, so the two cannot drift, and a
      -- new mint action that forgets its fee is a compile error there rather than a wrong number here.
      oracleProfileCreationFeeLovelace = Lookup.feeFor OnchainTypes.MintActionProfile <$> OnchainTypes.opFeeConfig p,
      oracleAttestationFeeLovelace = Lookup.feeFor OnchainTypes.MintActionAttestation <$> OnchainTypes.opFeeConfig p
    }

-- | The ledger witness a 'ClaimWitness' asks for.
--
-- This is the value 'Palmares.TxBuilding.Skeletons.txMustSpendFromAddress' now takes as a parameter
-- instead of hardcoding 'GYTxInWitnessKey' — the change that lets a script-held token be spent at
-- all, and therefore lets a script be a first-class issuer.
claimWitnessToTxInWitness :: ClaimWitness -> GYTxInWitness 'PlutusV3
claimWitnessToTxInWitness WitnessKey = GYTxInWitnessKey
claimWitnessToTxInWitness (WitnessSimpleScript s) = GYTxInWitnessSimpleScript (GYInSimpleScript s)
-- No datum: a PlutusV3 spend does not need one, and the claim's proving input is the caller's own
-- UTxO rather than protocol state whose datum we know.
claimWitnessToTxInWitness (WitnessPlutusScript sc r) = GYTxInWitnessScript (GYInScript sc) Nothing r

------------------------------------------------------------------------------------------------

-- * Dispute Conversions

------------------------------------------------------------------------------------------------

-- | Map the domain verdict to its on-chain representation.
--
-- Arm by arm, for the reason 'profileTypeToOnchainProfileKind' is: agreeing in order today is a
-- coincidence, not a contract.
disputeVerdictToOnchainVerdict :: DisputeVerdict -> OnchainTypes.Verdict
disputeVerdictToOnchainVerdict VerdictUpheld = OnchainTypes.VerdictUpheld
disputeVerdictToOnchainVerdict VerdictRejected = OnchainTypes.VerdictRejected
disputeVerdictToOnchainVerdict VerdictExpired = OnchainTypes.VerdictExpired

-- | Map an on-chain verdict to the domain one.
onchainVerdictToDisputeVerdict :: OnchainTypes.Verdict -> DisputeVerdict
onchainVerdictToDisputeVerdict OnchainTypes.VerdictUpheld = VerdictUpheld
onchainVerdictToDisputeVerdict OnchainTypes.VerdictRejected = VerdictRejected
onchainVerdictToDisputeVerdict OnchainTypes.VerdictExpired = VerdictExpired

-- | Extract 'ProfileData' from a CIP-68 profile datum's metadata fields.
profileDatumToProfileData :: CIP68Datum Onchain.OnchainProfile -> ProfileData
profileDatumToProfileData = metadataFieldsToProfileData . getMetadataFields

-- | Convert a full CIP-68 profile datum to a domain 'Profile' (metadata + extra fields).
profileDatumToProfile :: (MonadError GYTxMonadException m) => CIP68Datum Onchain.OnchainProfile -> m Profile
profileDatumToProfile datum = do
  let ProfileData {..} = profileDatumToProfileData datum
      onchainProfile = extra datum
  let profileType = onchainProfileKindToProfileType $ Onchain.profileKind onchainProfile
  gyProfileId <- assetClassFromPlutus' (Onchain.profileId onchainProfile)
  return $
    Profile
      { profileId = gyProfileId,
        profileName = profileDataName,
        profileDescription = profileDataDescription,
        profileImageURI = profileDataImageURI,
        profileType = profileType
      }

------------------------------------------------------------------------------------------------

-- * Attestation Conversions

------------------------------------------------------------------------------------------------

-- | CIP-68 metadata map keys reserved for standard fields ('mkCIP68Datum'), UTF-8 encoded.
cip68StandardMetadataKeys :: [BuiltinByteString]
cip68StandardMetadataKeys =
  [ textToBuiltinByteString "name",
    textToBuiltinByteString "description",
    textToBuiltinByteString "image"
  ]

-- | Key-value pairs from the datum metadata map excluding standard CIP-68 fields, sorted by key.
cip68DatumOtherMetadataPairs :: CIP68Datum a -> [(T.Text, T.Text)]
cip68DatumOtherMetadataPairs datum =
  sortOn fst $
    map
      ( Data.Bifunctor.bimap
          fromBuiltinByteStringUtf8
          fromBuiltinByteStringUtf8
      )
      ( filter
          (not . (`elem` cip68StandardMetadataKeys) . fst)
          (AssocMap.toList (metadata datum))
      )

-- | A claimed period only if both bounds are a date PostgreSQL can hold — audit `CS-01`.
--
-- __The one datum value with no on-chain bound at all.__ @attestationDate@ is bounded by @Mq@ to the
-- transaction's validity range, and every amount is bounded by @O6@; @attestationPeriod@ is
-- deliberately unchecked, because no on-chain fact can establish when an affiliation began. So the
-- issuer chooses it freely, and @POSIXTime 10^20@ is as valid a redeemer argument as last Tuesday.
--
-- That value reached a @timestamptz@ column. PostgreSQL rejects it, the projector's batch aborted,
-- the cursor never advanced, and the loop retried only Kupo client errors — so one hand-built
-- attestation, for about 1.3 ADA, halted the read layer permanently and no later block could ever be
-- indexed. The audit rated it the only Critical in the protocol and it was right.
--
-- __Clamped here rather than guarded at the database.__ This conversion is the single boundary every
-- datum crosses on its way to a projection, so one check covers the ingest path, the replay path and
-- any future reader; a guard in @Storage@ would be one guard per column. A period outside the
-- representable range becomes 'Nothing', which is a true statement about what the read layer can
-- show — and the attestation itself survives, which matters more: the record is the thing the
-- registry promises, and a self-reported date nobody can render is not worth losing it for.
--
-- __What this does NOT fix.__ 'Palmares.ChainSync.ChainSyncLogic.applyMatches' still applies a whole
-- window in one transaction, so any OTHER unrepresentable value would still abort the batch rather
-- than one row. That is the second half of `CS-01` and it is a change to the sync loop's ordering and
-- idempotency, not a boundary check. Left open deliberately; this half removes the only value the
-- chain actually lets a stranger choose.
representablePeriod :: Maybe (POSIXTime, POSIXTime) -> Maybe (GYTime, GYTime)
representablePeriod mp = do
  -- Not `from`/`to`: both are `PlutusLedgerApi.V1.Interval` constructors this module imports
  -- unqualified, and shadowing an interval constructor inside a date check is the kind of name
  -- collision that reads fine and means something else.
  (periodFrom, periodTo) <- mp
  if representable periodFrom && representable periodTo
    then Just (timeFromPlutus periodFrom, timeFromPlutus periodTo)
    else Nothing
  where
    -- PostgreSQL's `timestamptz` spans 4713 BC to 294276 AD. The window below is far tighter and
    -- deliberately so: a claimed governance mandate outside 1970-2970 is not a near-miss on a
    -- storage limit, it is a value nobody meant. Milliseconds, as `POSIXTime` is — 31556952000000
    -- is a thousand Julian years of them. No underscores: this library does not enable
    -- `NumericUnderscores`, and the first draft of this line assumed it did.
    representable (POSIXTime ms) = ms >= 0 && ms <= 31556952000000

-- | Convert a CIP-68 attestation datum to a domain 'Attestation'.
onchainAttestationToAttestation :: (MonadError GYTxMonadException m) => CIP68Datum OnchainTypes.OnchainAttestation -> m Attestation
onchainAttestationToAttestation datum = do
  let OnchainTypes.OnchainAttestation {..} = extra datum
      ProfileData {..} = metadataFieldsToProfileData (getMetadataFields datum)
      otherMeta = cip68DatumOtherMetadataPairs datum
  gyAttestationId <- assetClassFromPlutus' attestationId
  gySubject <- assetClassFromPlutus' attestationSubject
  gyIssuer <- assetClassFromPlutus' attestationIssuer
  -- Bound to locals rather than written inline, because `RecordWildCards` above has already brought
  -- the ON-CHAIN `attestationKind` into scope under the same name the off-chain field uses. Reading
  -- `attestationKind = f attestationKind` and having to know which side each one is on is how a
  -- conversion gets inverted; `attestationId`/`gyAttestationId` above is the same guard.
  let gyKind = onchainAttestationKindToAttestationType attestationKind
      gyClaimedPeriod = representablePeriod attestationPeriod
  return
    Attestation
      { attestationId = gyAttestationId,
        attestationSubjectProfileId = gySubject,
        attestationIssuerProfileId = gyIssuer,
        attestationKind = gyKind,
        -- Bound inline and not to a local, unlike `gyKind`: the on-chain field `attestationCredential`
        -- is in scope under the same name, but it is a `Maybe Credential` and the off-chain field is
        -- a `Maybe Text`, so the two cannot be confused for each other the way two kinds could.
        attestationCredential = claimCredentialToText <$> attestationCredential,
        attestationAttestationDate = timeFromPlutus attestationDate,
        attestationClaimedPeriod = gyClaimedPeriod,
        attestationAccepted = attestationIsAccepted,
        attestationName = profileDataName,
        attestationDescription = profileDataDescription,
        attestationImageURI = profileDataImageURI,
        attestationOtherMetadata = otherMeta,
        -- ponytail: live backend doesn't thread the UTxO ref; tx pointer is projected-only.
        attestationTxHash = Nothing,
        attestationSlot = Nothing,
        attestationOutputIndex = Nothing
      }
