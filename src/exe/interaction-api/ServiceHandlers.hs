


-- | Service-layer handlers for the interaction API's dedicated endpoints.
-- Each handler resolves a service request into an 'Interaction' and delegates
-- to the existing tx-building pipeline via 'buildInteractionApp'.
module ServiceHandlers where

import Palmares.DomainTypes.Core.Actions
import GeniusYield.Types (GYAddress)
import InteractionAppMonad
import ServiceRequests
import Palmares.TxBuilding.Interactions (ActionType (..), Interaction (..), UserAddresses)

-------------------------------------------------------------------------------

-- * Helpers

-------------------------------------------------------------------------------

-- | Build an 'Interaction' from a profile action, user addresses, and optional recipient.
mkInteraction :: ProfileActionType -> UserAddresses -> Maybe GYAddress -> Interaction
mkInteraction actionType = Interaction (ProfileAction actionType)

-------------------------------------------------------------------------------

-- * Handlers

-------------------------------------------------------------------------------

-- | Update a profile's mutable metadata.
handleUpdateProfile :: UpdateProfileRequest -> InteractionAppMonad String
handleUpdateProfile req = do
  let action = UpdateProfileAction (uprProfileId req) (uprDescription req) (uprImageURI req)
  buildInteractionApp $ mkInteraction action (uprUserAddresses req) (uprRecipient req)

-- | Issue an attestation about a subject profile.
handleAwardAchievement :: AwardAchievementRequest -> InteractionAppMonad String
handleAwardAchievement req = do
  let pd = ProfileData (aarName req) (aarDescription req) (aarImageURI req)
  let action = AwardAchievementAction
        (aarAwardedToProfileId req)
        (aarAwardedByProfileId req)
        pd
        (aarOtherMetadata req)
        (aarAchievementDate req)
  buildInteractionApp $ mkInteraction action (aarUserAddresses req) (aarRecipient req)

-------------------------------------------------------------------------------

-- * Pass-through handlers (thin wrappers)

-------------------------------------------------------------------------------

handleAcceptAchievement :: AcceptAchievementRequest -> InteractionAppMonad String
handleAcceptAchievement req = buildInteractionApp $ mkInteraction
  (AcceptAchievementAction (acrAchievementId req))
  (acrUserAddresses req)
  (acrRecipient req)
