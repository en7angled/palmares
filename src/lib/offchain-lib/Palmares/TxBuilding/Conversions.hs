-- | Bidirectional conversions between on-chain Plutus types and off-chain domain types.
module Palmares.TxBuilding.Conversions where

import Data.Bifunctor qualified
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Ids (drepIdCip129, parseCredentialCip129)
import Palmares.DomainTypes.Core.Types
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.Onchain.CIP68 (CIP68Datum (..), MetadataFields (..), extra, getMetadataFields)
import Palmares.Onchain.Protocol qualified as Onchain
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

-- | Map an on-chain attestation kind to the domain 'AttestationType'.
onchainAttestationKindToAttestationType :: Onchain.AttestationKind -> AttestationType
onchainAttestationKindToAttestationType Onchain.MilestoneDelivered = MilestoneDelivered
onchainAttestationKindToAttestationType Onchain.AuditPassed = AuditPassed
onchainAttestationKindToAttestationType Onchain.Affiliation = Affiliation
onchainAttestationKindToAttestationType Onchain.RoleHeld = RoleHeld
onchainAttestationKindToAttestationType Onchain.Endorsement = Endorsement

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
parseClaimCredential :: T.Text -> Either TxBuildingException Credential
parseClaimCredential t = case parseCredentialCip129 t of
  Just (True, raw) -> Right (ScriptCredential (ScriptHash (toBuiltin raw)))
  Just (False, raw) -> Right (PubKeyCredential (PubKeyHash (toBuiltin raw)))
  Nothing -> Left CredentialMalformed

-- | The CIP-129 rendering of a claimed credential — the inverse of 'parseClaimCredential'.
--
-- The HRP is @drep@ because a 'Credential' is 28 bytes plus the key-or-script flag and nothing else:
-- which governance role those bytes play is the profile's @kind@, not part of the credential, and the
-- on-chain datum stores no HRP either. So a committee cold credential claimed as @cc_cold1…@ reads
-- back as the @drep1…@ rendering of the same credential, which is the same bytes and the same flag.
claimCredentialToText :: Credential -> T.Text
claimCredentialToText (ScriptCredential (ScriptHash bs)) = drepIdCip129 True (fromBuiltin bs)
claimCredentialToText (PubKeyCredential (PubKeyHash bs)) = drepIdCip129 False (fromBuiltin bs)

-- | Is this credential a script rather than a key? The two take different proofs of control.
isScriptCredential :: Credential -> Bool
isScriptCredential (ScriptCredential _) = True
isScriptCredential (PubKeyCredential _) = False

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

-- | Map an on-chain verdict to the domain one.
onchainVerdictToDisputeVerdict :: OnchainTypes.Verdict -> DisputeVerdict
onchainVerdictToDisputeVerdict OnchainTypes.VerdictUpheld = VerdictUpheld
onchainVerdictToDisputeVerdict OnchainTypes.VerdictRejected = VerdictRejected

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
      gyClaimedPeriod = fmap (Data.Bifunctor.bimap timeFromPlutus timeFromPlutus) attestationPeriod
  return
    Attestation
      { attestationId = gyAttestationId,
        attestationSubjectProfileId = gySubject,
        attestationIssuerProfileId = gyIssuer,
        attestationKind = gyKind,
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
