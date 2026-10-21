{-# LANGUAGE OverloadedStrings #-}

module Test.Fixtures
  ( adminTestProfileData,
    studentProfileData,
    masterProfileData,
    masterBProfileData,
    orgProfileData,
    practitionerProfileData,
    practitionerBProfileData,
    practitionerCProfileData,
    attestationProfileData,
    seminarProfileData,
    cleanupTestProfileData,
    profileDataMaxLengthMetadata,
    attestationProfileDataMaxLength,
    maxLengthImageURI,
    profileDataOverLongName,
    parsingDisputeDatum,
  )
where

import Data.Text (Text, pack)
import Palmares.DomainTypes.Core.Actions (ProfileData (..))
import Palmares.Onchain.CIP68 (CIP68Datum (..))
import Palmares.Onchain.Protocol.Types (OnchainDispute (..))
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import PlutusLedgerApi.V3 (Address (..), Credential (PubKeyCredential), POSIXTime (..), PubKeyHash (..))
import PlutusTx.AssocMap qualified as AssocMap

adminTestProfileData :: ProfileData
adminTestProfileData =
  ProfileData
    { profileDataName = "Admin Test User",
      profileDataDescription = "A test profile for admin action tests",
      profileDataImageURI = "ipfs://QmAdminTest"
    }

studentProfileData :: ProfileData
studentProfileData =
  ProfileData
    { profileDataName = "John Doe",
      profileDataDescription = "John Doe is a student",
      profileDataImageURI = "ipfs://QmReBRNMe7tBr6WbA89uwnHHW7f7Zoe8wY2mzVpA8STdAk"
    }

masterProfileData :: ProfileData
masterProfileData =
  ProfileData
    { profileDataName = "Master",
      profileDataDescription = "Master is a master",
      profileDataImageURI = "ipfs://Qmb3JXJHQxuReSUaH6rXAoP5oX9NRs6JmnRFGTj2RVhGwe"
    }

masterBProfileData :: ProfileData
masterBProfileData =
  ProfileData
    { profileDataName = "Master B",
      profileDataDescription = "Master B is also a master",
      profileDataImageURI = "ipfs://QmMasterB"
    }

orgProfileData :: ProfileData
orgProfileData =
  ProfileData
    { profileDataName = "BJJ Academy",
      profileDataDescription = "A BJJ Academy Organization",
      profileDataImageURI = "ipfs://QmOrgAcademy"
    }

practitionerProfileData :: ProfileData
practitionerProfileData =
  ProfileData
    { profileDataName = "Practitioner A",
      profileDataDescription = "A practitioner member",
      profileDataImageURI = "ipfs://QmPractitionerA"
    }

practitionerBProfileData :: ProfileData
practitionerBProfileData =
  ProfileData
    { profileDataName = "Practitioner B",
      profileDataDescription = "Second practitioner member",
      profileDataImageURI = "ipfs://QmPractitionerB"
    }

practitionerCProfileData :: ProfileData
practitionerCProfileData =
  ProfileData
    { profileDataName = "Practitioner C",
      profileDataDescription = "Third practitioner member",
      profileDataImageURI = "ipfs://QmPractitionerC"
    }

attestationProfileData :: ProfileData
attestationProfileData =
  ProfileData
    { profileDataName = "Gold Medal",
      profileDataDescription = "Won gold medal at tournament",
      profileDataImageURI = "ipfs://QmGoldMedal"
    }

seminarProfileData :: ProfileData
seminarProfileData =
  ProfileData
    { profileDataName = "Advanced Seminar",
      profileDataDescription = "Attended advanced seminar",
      profileDataImageURI = "ipfs://QmSeminar"
    }

cleanupTestProfileData :: ProfileData
cleanupTestProfileData =
  ProfileData
    { profileDataName = "Cleanup Test User",
      profileDataDescription = "A test profile to verify dust cleanup safety",
      profileDataImageURI = "ipfs://QmCleanupTest"
    }

-- Max-length metadata (bytes): name 128, description 1024, image URI 256 (Onchain.CIP68).
-- ASCII so 1 char = 1 byte.
maxLengthImageURI :: Text
maxLengthImageURI = pack ("ipfs://Qm" ++ replicate 246 'x') -- 10 + 246 = 256 bytes

profileDataMaxLengthMetadata :: ProfileData
profileDataMaxLengthMetadata =
  ProfileData
    { profileDataName = pack (replicate 128 'a'),
      profileDataDescription = pack (replicate 1024 'b'),
      profileDataImageURI = maxLengthImageURI
    }

attestationProfileDataMaxLength :: ProfileData
attestationProfileDataMaxLength = profileDataMaxLengthMetadata

-- 129-byte name (over maxNameLength 128) for negative tests; description and image within limits.
profileDataOverLongName :: ProfileData
profileDataOverLongName =
  ProfileData
    { profileDataName = pack (replicate 129 'a'),
      profileDataDescription = "ok",
      profileDataImageURI = "ipfs://QmOk"
    }

-- | A datum that __parses__ as the Disputes Validator's state.
--
-- It is not a dispute any transaction could have produced — no protocol token backs it, the asset
-- classes are made up and the metadata map is empty. That is the point: the @Cleanup@ redeemer's
-- guard is @fromBuiltinData@ succeeding and nothing else, so this is the cheapest thing that
-- reaches it. Paired with 'TestRuns.lockParsingDatumAt', which locks it with no protocol token so
-- the dust sweep selects it.
parsingDisputeDatum :: CIP68Datum OnchainDispute
parsingDisputeDatum =
  CIP68Datum
    { metadata = AssocMap.empty,
      version = 1,
      extra =
        OnchainDispute
          { disputeId = fakeAC "dispute",
            disputeTarget = fakeAC "target",
            disputeOpenedBy = fakeAC "opener",
            disputeOpenedAt = POSIXTime 1700000000000,
            disputeDeposit = 5000000,
            disputeDepositTo = Address (PubKeyCredential (PubKeyHash "")) Nothing,
            disputeOracleToken = fakeAC "oracle",
            disputeVerdict = Nothing
          }
    }
  where
    fakeAC name = AssetClass (CurrencySymbol "", TokenName name)
