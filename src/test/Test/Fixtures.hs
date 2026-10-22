{-# LANGUAGE OverloadedStrings #-}

-- | Profile and attestation content the emulator tests mint.
--
-- __Renamed, not rewritten.__ These were BJJ fixtures (@studentProfileData@, @masterProfileData@) and
-- the names were the only thing coupling them to that domain: 'ProfileData' is three text fields and
-- the protocol does not read them. What matters is that distinct fixtures stay distinguishable, so a
-- transposition between two of them fails an assertion instead of passing by coincidence.
--
-- The last four are a different kind of fixture and are pinned, not decorative: they sit exactly on
-- 'Palmares.Onchain.CIP68''s byte limits (name 128, description 1024, image URI 256) and one byte
-- over, so they are what makes @Mp4@/@Mm@/@P4@ testable at the boundary. Do not round them off.
module Test.Fixtures
  ( -- * Profiles
    drepProfileData,
    drepBProfileData,
    orgProfileData,
    committeeProfileData,
    communityProfileData,
    auditorProfileData,
    cleanupTestProfileData,

    -- * Attestations and disputes
    milestoneAttestationData,
    auditAttestationData,
    lineageAttestationData,
    disputeStatementData,

    -- * Metadata byte boundaries (pinned against Onchain.CIP68)
    profileDataMaxLengthMetadata,
    attestationProfileDataMaxLength,
    maxLengthImageURI,
    profileDataOverLongName,

    -- * Cleanup
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

-- | A person acting as a DRep — the protocol's central profile kind.
drepProfileData :: ProfileData
drepProfileData =
  ProfileData
    { profileDataName = "Ana Pop",
      profileDataDescription = "A delegate representative voting on governance actions",
      profileDataImageURI = "ipfs://QmDrepAna"
    }

-- | A second DRep, deliberately distinguishable from the first.
drepBProfileData :: ProfileData
drepBProfileData =
  ProfileData
    { profileDataName = "Bogdan Ilie",
      profileDataDescription = "A second delegate representative",
      profileDataImageURI = "ipfs://QmDrepBogdan"
    }

orgProfileData :: ProfileData
orgProfileData =
  ProfileData
    { profileDataName = "Sundae Labs",
      profileDataDescription = "An organisation that delivers funded work",
      profileDataImageURI = "ipfs://QmOrgSundae"
    }

committeeProfileData :: ProfileData
committeeProfileData =
  ProfileData
    { profileDataName = "Constitutional Committee Seat",
      profileDataDescription = "A committee member acting through its cold credential",
      profileDataImageURI = "ipfs://QmCommitteeSeat"
    }

-- | A Community, which claims no credential at all: the profile kind that proves a claim is optional.
communityProfileData :: ProfileData
communityProfileData =
  ProfileData
    { profileDataName = "Intersect Community",
      profileDataDescription = "A community that corresponds to no on-chain credential",
      profileDataImageURI = "ipfs://QmCommunity"
    }

auditorProfileData :: ProfileData
auditorProfileData =
  ProfileData
    { profileDataName = "Tweag Audit",
      profileDataDescription = "An auditor that attests to delivered milestones",
      profileDataImageURI = "ipfs://QmAuditor"
    }

cleanupTestProfileData :: ProfileData
cleanupTestProfileData =
  ProfileData
    { profileDataName = "Cleanup Test Profile",
      profileDataDescription = "A profile that must survive a dust sweep untouched",
      profileDataImageURI = "ipfs://QmCleanupTest"
    }

milestoneAttestationData :: ProfileData
milestoneAttestationData =
  ProfileData
    { profileDataName = "Milestone 3 delivered",
      profileDataDescription = "The third milestone of Catalyst Fund 12 project 1200123 was delivered",
      profileDataImageURI = "ipfs://QmMilestone3"
    }

auditAttestationData :: ProfileData
auditAttestationData =
  ProfileData
    { profileDataName = "Audit passed",
      profileDataDescription = "The validator set passed an external security audit",
      profileDataImageURI = "ipfs://QmAuditPassed"
    }

-- | An attestation ABOUT an attestation. Its subject is another attestation's id, which the protocol
-- permits on purpose — see 'Palmares.TxBuilding.Lookups.ensureSubjectProfileExists'.
lineageAttestationData :: ProfileData
lineageAttestationData =
  ProfileData
    { profileDataName = "Endorsement of an endorsement",
      profileDataDescription = "A second issuer endorses an earlier attestation rather than its subject",
      profileDataImageURI = "ipfs://QmLineage"
    }

disputeStatementData :: ProfileData
disputeStatementData =
  ProfileData
    { profileDataName = "Milestone was not delivered",
      profileDataDescription = "The disputer's statement: the deliverable named in the attestation does not exist",
      profileDataImageURI = "ipfs://QmDisputeStatement"
    }

-- Max-length metadata (bytes): name 128, description 1024, image URI 256 (Onchain.CIP68).
-- ASCII so 1 char = 1 byte.
-- `ipfs://Qm` is NINE characters, and this said 10 until 2026-10-22, so every fixture built from it
-- sat one byte UNDER the limit it exists to sit on — the one block in this module whose whole job is
-- to make `Mm`/`Mp4`/`P4` testable at the boundary, missing the boundary it names in its own comment.
maxLengthImageURI :: Text
maxLengthImageURI = pack ("ipfs://Qm" ++ replicate 247 'x') -- 9 + 247 = 256 bytes

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
