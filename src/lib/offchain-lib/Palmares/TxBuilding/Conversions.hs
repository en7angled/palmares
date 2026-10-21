-- | Bidirectional conversions between on-chain Plutus types and off-chain domain types.
module Palmares.TxBuilding.Conversions where

import Data.Bifunctor qualified
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types
import GeniusYield.TxBuilder
import GeniusYield.Types
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
  return
    Attestation
      { attestationId = gyAttestationId,
        attestationSubjectProfileId = gySubject,
        attestationIssuerProfileId = gyIssuer,
        attestationAttestationDate = timeFromPlutus attestationDate,
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
