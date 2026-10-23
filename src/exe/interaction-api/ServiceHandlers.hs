


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

-- | The same, for a dispute action.
mkDisputeInteraction :: DisputeActionType -> UserAddresses -> Maybe GYAddress -> Interaction
mkDisputeInteraction actionType = Interaction (DisputeAction actionType)

-------------------------------------------------------------------------------

-- * Handlers

-------------------------------------------------------------------------------

-- | Mint a profile, optionally claiming a Cardano credential.
handleClaimProfile :: ClaimProfileRequest -> InteractionAppMonad String
handleClaimProfile req = do
  let pd = ProfileData (cprName req) (cprDescription req) (cprImageURI req)
  -- No credential: a profile mint claims nothing (ADR 0003). /claim-credential is the binding.
  let action = ClaimProfileAction (cprKind req) pd
  buildInteractionApp $ mkInteraction action (cprUserAddresses req) (cprRecipient req)

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

-------------------------------------------------------------------------------

-- * Dispute handlers

-------------------------------------------------------------------------------

-- | Open a dispute against an attestation.
handleOpenDispute :: OpenDisputeRequest -> InteractionAppMonad String
handleOpenDispute req = do
  let pd = ProfileData (odrName req) (odrDescription req) (odrImageURI req)
  let action = OpenDisputeAction (odrAttestationId req) (odrOpenedByProfileId req) (odrDepositTo req) pd
  buildInteractionApp $ mkDisputeInteraction action (odrUserAddresses req) (odrRecipient req)

-- | Settle a dispute. Returns an unsigned transaction for the admin to sign.
handleResolveDispute :: ResolveDisputeRequest -> InteractionAppMonad String
handleResolveDispute req = buildInteractionApp $ mkDisputeInteraction
  (ResolveDisputeAction (rdrDisputeId req) (rdrVerdict req))
  (rdrUserAddresses req)
  (rdrRecipient req)

-- | Close an undecided dispute whose deadline has passed — D-A. Takes no verdict: the caller does
-- not choose the outcome here, the clock does.
handleExpireDispute :: ExpireDisputeRequest -> InteractionAppMonad String
handleExpireDispute req = buildInteractionApp $ mkDisputeInteraction
  (ExpireDisputeAction (edrDisputeId req))
  (edrUserAddresses req)
  (edrRecipient req)

-- | Bind a profile to a credential — ADR 0003. Both parties consent: the profile's user token and
-- the credential's own proof, in one appended record.
handleClaimCredential :: ClaimCredentialRequest -> InteractionAppMonad String
handleClaimCredential req = do
  let pd = ProfileData (cclName req) (cclDescription req) (cclImageURI req)
      action = ClaimCredentialAction (cclProfileId req) (cclCredential req) (cclWitness req) pd
  buildInteractionApp $ mkInteraction action (cclUserAddresses req) (cclRecipient req)

-- | End a binding — ADR 0003. The credential's proof alone, and the profile's user token
-- deliberately not asked for: the case this exists for is a profile that claimed somebody else's
-- credential, and that token is held by whoever did it. Nothing is erased; a fact is appended.
handleWithdrawCredential :: WithdrawCredentialRequest -> InteractionAppMonad String
handleWithdrawCredential req = do
  let pd = ProfileData (wclName req) (wclDescription req) (wclImageURI req)
      action = WithdrawCredentialAction (wclProfileId req) (wclCredential req) (wclWitness req) pd
  buildInteractionApp $ mkInteraction action (wclUserAddresses req) (wclRecipient req)
