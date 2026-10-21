


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
handleIssueAttestation :: IssueAttestationRequest -> InteractionAppMonad String
handleIssueAttestation req = do
  let pd = ProfileData (iarName req) (iarDescription req) (iarImageURI req)
  let action = IssueAttestationAction
        (iarSubjectProfileId req)
        (iarIssuerProfileId req)
        (iarKind req)
        pd
        (iarOtherMetadata req)
        (iarClaimedPeriod req)
  buildInteractionApp $ mkInteraction action (iarUserAddresses req) (iarRecipient req)

-------------------------------------------------------------------------------

-- * Pass-through handlers (thin wrappers)

-------------------------------------------------------------------------------

handleAcceptAttestation :: AcceptAttestationRequest -> InteractionAppMonad String
handleAcceptAttestation req = buildInteractionApp $ mkInteraction
  (AcceptAttestationAction (acrAttestationId req))
  (acrUserAddresses req)
  (acrRecipient req)
