{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- | Chain event projection: maps raw on-chain UTxO datums to domain-level events.
--
-- __Nothing here trusts an address, and that is inherited fix #3.__ Anyone can pay 2 ADA and a
-- hand-crafted inline datum to any script address, and no validator ever runs on an output nobody
-- spends — so dispatching on @(address, datum parses)@ alone let an attacker plant a profile or an
-- attestation that the read API then served as protocol state. Every branch below therefore calls
-- 'authenticateStateUTxO' on the id the datum names BEFORE the datum becomes an event, and an
-- output that fails it is 'NoEvent': indistinguishable, downstream, from a UTxO at an address we
-- do not index.
module Palmares.Ingestion where

import Data.Maybe (isJust)
import Data.Text (Text)
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.ChainSync.KupoAtlas
import Palmares.DomainTypes.Core.Actions (ProfileData (..))
import Palmares.DomainTypes.Core.Types
import Palmares.Onchain.CIP68 (CIP68Datum, extra, getMetadataFields)
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.TxBuilding.Conversions
import Palmares.TxBuilding.Utils
import Palmares.TxBuilding.Validators (attestationsValidatorHashGY, disputesValidatorHashGY, profilesValidatorHashGY)

-- | A dispute, read off its on-chain datum and ready for 'Palmares.Storage.putDisputeProjection'.
--
-- Its own record rather than a domain type: there is no off-chain @Dispute@ to convert to, and the
-- read surface builds its DTO from the projection row rather than from here. Named fields and not a
-- tuple because 'pdDisputeId', 'pdTarget' and 'pdOpenedBy' are all 'GYAssetClass' — a transposition
-- among them would compile and attribute a dispute to the wrong attestation, which is the failure
-- 'Palmares.Storage.putAttestationProjection' documents in the larger table.
data ProjectedDispute = ProjectedDispute
  { pdDisputeId :: GYAssetClass,
    pdTarget :: GYAssetClass,
    pdOpenedBy :: GYAssetClass,
    pdOpenedAt :: GYTime,
    pdDeposit :: Integer,
    -- | 'Nothing' while the dispute is open. Set once, and never unset.
    pdVerdict :: Maybe DisputeVerdict,
    pdName :: Text,
    pdDescription :: Text,
    pdImageURI :: Text
  }
  deriving (Show)

-- | Classified domain event produced by projecting an on-chain UTxO datum.
data ChainEventProjection
  = -- | A profile.
    --
    -- __No credential any more — ADR 0003.__ It used to carry the CIP-129 rendering of the
    -- credential the profile claimed, read straight off the profile datum. A binding is now a
    -- 'Palmares.DomainTypes.Core.Types.CredentialClaim' attestation, so it arrives as an
    -- 'AttestationEvent' and the read layer derives @profile_credential@ from the attestation
    -- stream rather than from this event.
    ProfileEvent Profile
  | AttestationEvent Attestation
  | DisputeEvent ProjectedDispute
  | NoEvent AtlasMatch
  deriving (Show)

-- | A dispute datum from an output's datum, or 'Nothing' when it is absent or is not a dispute.
--
-- The sibling of 'profileFromGYOutDatum' and 'attestationFromGYOutDatum', which live in
-- "Palmares.TxBuilding.Utils" beside the rest of the datum parsers; this one is here only because
-- that module was not ours to edit in this change.
disputeFromGYOutDatum :: GYOutDatum -> Maybe (CIP68Datum OnchainTypes.OnchainDispute)
disputeFromGYOutDatum (GYOutDatumInline gyDatum) = disputeDatumFromDatum gyDatum
disputeFromGYOutDatum _ = Nothing

-- | Project an 'AtlasMatch' into a domain event by inspecting the validator address, the datum and
-- __the value__. Spent UTxOs are ignored (returned as 'NoEvent').
--
-- The minting policy id is the protocol's own: it is what makes the token in the output's value
-- proof of authenticity rather than a name anyone can reuse. attest-sync derives it from the same
-- deployed-policy hash it builds its Kupo match pattern from, so an output this function accepts is
-- one the indexer could have matched.
projectChainEvent ::
  (MonadError GYTxMonadException m) =>
  GYNetworkId ->
  -- | The protocol minting policy — see 'authenticateStateUTxO'.
  GYMintingPolicyId ->
  AtlasMatch ->
  m ChainEventProjection
projectChainEvent nid ourPolicy am@AtlasMatch {..}
  | isJust amSpentAt = return (NoEvent am)
  | amAddress == validatorAddress profilesValidatorHashGY =
      case profileFromGYOutDatum amDatum of
        Just datum
          | authentic (OnchainTypes.profileId (extra datum)) ->
              ProfileEvent <$> profileDatumToProfile datum
        _ -> return (NoEvent am)
  | amAddress == validatorAddress attestationsValidatorHashGY =
      case attestationFromGYOutDatum amDatum of
        Just datum
          | authentic (OnchainTypes.attestationId (extra datum)) ->
              AttestationEvent <$> onchainAttestationToAttestation datum
        _ -> return (NoEvent am)
  | amAddress == validatorAddress disputesValidatorHashGY =
      case disputeFromGYOutDatum amDatum of
        Just datum
          | authentic (OnchainTypes.disputeId (extra datum)) ->
              DisputeEvent <$> projectDispute datum
        _ -> return (NoEvent am)
  | otherwise = return (NoEvent am)
  where
    -- Not `scriptAddress`: "GeniusYield.TxBuilder", imported openly above, exports that name and
    -- `scriptAddress'`, both monadic and taking the network id from the monad. This one is pure and
    -- is handed `nid`, so shadowing theirs hid a real difference behind the same word.
    validatorAddress = addressFromScriptHash nid
    -- The gate. An id the ledger cannot even represent as an asset class fails it, rather than
    -- being converted with 'assetClassFromPlutus'' and throwing: a forged datum must be skipped,
    -- not turned into a projection error that stops the batch.
    authentic claimedId = case assetClassFromPlutus claimedId of
      Left _ -> False
      Right ac -> authenticateStateUTxO ourPolicy ac amValue

-- | Convert an authenticated CIP-68 dispute datum into its projection payload.
projectDispute :: (MonadError GYTxMonadException m) => CIP68Datum OnchainTypes.OnchainDispute -> m ProjectedDispute
projectDispute datum = do
  let OnchainTypes.OnchainDispute {..} = extra datum
      ProfileData {..} = metadataFieldsToProfileData (getMetadataFields datum)
  -- Bound to locals first, for the reason 'onchainAttestationToAttestation' gives: RecordWildCards
  -- has brought the on-chain names into scope, so converting inline would read as `x = f x`.
  gyDisputeId <- assetClassFromPlutus' disputeId
  gyTarget <- assetClassFromPlutus' disputeTarget
  gyOpenedBy <- assetClassFromPlutus' disputeOpenedBy
  return
    ProjectedDispute
      { pdDisputeId = gyDisputeId,
        pdTarget = gyTarget,
        pdOpenedBy = gyOpenedBy,
        pdOpenedAt = timeFromPlutus disputeOpenedAt,
        pdDeposit = disputeDeposit,
        pdVerdict = onchainVerdictToDisputeVerdict <$> disputeVerdict,
        pdName = profileDataName,
        pdDescription = profileDataDescription,
        pdImageURI = profileDataImageURI
      }

--- No need to delete profile projections since the profile cannot be deleted onchain;
