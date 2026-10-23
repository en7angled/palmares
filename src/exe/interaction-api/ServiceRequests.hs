{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Service-level request types for the interaction API's dedicated endpoints.
-- These are higher-level than 'ActionType': each carries the CIP-30 wallet contract
-- (used addresses, change address, optional recipient) plus the structured request
-- fields, and 'ServiceHandlers' resolves them into 'Interaction' values.
module ServiceRequests where

import Control.Lens ((&), (?~), at, mapped)
import Data.Swagger (ToSchema (..), description, genericDeclareNamedSchema, properties)
import Data.Swagger qualified as Swagger
import Data.Text (Text)
import Deriving.Aeson
import Palmares.DomainTypes.Core.Actions (ClaimWitness)
import Palmares.DomainTypes.Core.Types (AttestationAC, AttestationType, DisputeVerdict, ProfileRefAC, ProfileType)
import GeniusYield.Types (GYAddress, GYAssetClass)
import GeniusYield.Types.Time (GYTime)
import Palmares.TxBuilding.Interactions (UserAddresses)
import Palmares.Utils (mkStripPrefixSchemaOptions)

-------------------------------------------------------------------------------

-- * Helpers

-------------------------------------------------------------------------------

-- | Add a description to an inline field in a NamedSchema's properties.
describeField :: Text -> Text -> Swagger.NamedSchema -> Swagger.NamedSchema
describeField field desc ns =
  ns & Swagger.schema . properties . at field . mapped . Swagger._Inline . description ?~ desc

-------------------------------------------------------------------------------

-- * Request types

-------------------------------------------------------------------------------

-- | Mint a profile. It claims no credential — __ADR 0003__.
--
-- A binding is a record of its own, created by @\/claim-credential@ in a second transaction, so
-- that it can be ended by appending a fact instead of clearing a field. Four of the six profile
-- kinds correspond to no on-chain credential at all and never need that second call.
data ClaimProfileRequest = ClaimProfileRequest
  { cprKind :: ProfileType
  , cprName :: Text
  , cprDescription :: Text
  , cprImageURI :: Text
  , cprUserAddresses :: UserAddresses
  , cprRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "cpr", CamelToSnake]] ClaimProfileRequest

instance ToSchema ClaimProfileRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "cpr") proxy
    return $ s
      -- `recipient` and `kind` are described HERE and not with `describeField`, because
      -- each of those properties is a bare `$ref` and a Swagger 2.0 $ref cannot carry a sibling
      -- description — measured: the key is simply absent from the generated document. Same reason
      -- `IssueAttestationRequest` below has no `describeField "kind"`.
      & Swagger.schema . description
        ?~ "Mint a profile. It claims no credential: since ADR 0003 a binding is its own record, so \
           \bind the profile with POST /claim-credential afterwards. `recipient` receives any \
           \unlocked funds and defaults to the change address."
      & describeField "name" "Profile name. Immutable once minted."
      & describeField "description" "Profile description"
      & describeField "image_uri" "URI of the profile image (the client hosts it; the protocol stores the URI)"

-- | Update a profile's mutable metadata (description, image URI); the name is immutable.
data UpdateProfileRequest = UpdateProfileRequest
  { uprProfileId :: ProfileRefAC
  , uprUserAddresses :: UserAddresses
  , uprRecipient :: Maybe GYAddress
  , uprDescription :: Maybe Text
  , uprImageURI :: Text
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "upr", CamelToSnake]] UpdateProfileRequest

instance ToSchema UpdateProfileRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "upr") proxy
    return $ s
      & Swagger.schema . description ?~ "Update a profile's metadata (description, image). Name is immutable."
      & describeField "recipient" "Address to receive unlocked funds (defaults to change address if omitted)"
      & describeField "description" "New profile description (omit to keep current)"
      & describeField "image_uri" "URI of the profile image (the client hosts it; the protocol stores the URI)"

-- | Issue an attestation about a subject profile.
data IssueAttestationRequest = IssueAttestationRequest
  { iarSubjectProfileId :: ProfileRefAC
  , iarIssuerProfileId :: ProfileRefAC
  , iarKind :: AttestationType
  , iarName :: Text
  , iarDescription :: Text
  , iarImageURI :: Text
  , iarOtherMetadata :: [(Text, Text)]
  -- The issuance date is NOT a request field. It is derived from the chain tip, because the minting
  -- policy requires it to be contained in the transaction's validity interval (Ml, inherited fix #4)
  -- and that interval is built from the tip — so a client-supplied date had exactly one acceptable
  -- value and every other value was a 400.
  , iarClaimedPeriod :: Maybe (GYTime, GYTime)
  , iarUserAddresses :: UserAddresses
  , iarRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "iar", CamelToSnake]] IssueAttestationRequest

instance ToSchema IssueAttestationRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "iar") proxy
    return $ s
      & Swagger.schema . description ?~ "Issue an attestation to a profile."
      & describeField "name" "Attestation name"
      & describeField "description" "Attestation description"
      & describeField "image_uri" "URI of the attestation image (the client hosts it; the protocol stores the URI)"
      & describeField "other_metadata" "Additional key-value metadata pairs (e.g. [[\"category\", \"competition\"]])"
      -- No `describeField "kind"`: the property is a bare `$ref` to AttestationType, and a Swagger
      -- 2.0 $ref cannot carry a sibling description — measured, the key was simply absent from the
      -- generated document. The definition-level description in `addSharedSwaggerDescriptions` is
      -- the mechanism for a $ref'd type, which is why that table already had an AttestationType row
      -- before the type existed.
      & describeField "claimed_period" "Optional [from, to] period the attestation CLAIMS, e.g. the span of an affiliation or a mandate. SELF-REPORTED: no on-chain fact can establish it, so it is never presented as verified, and only its ordering (from <= to) is checked. Both bounds or neither."
      & describeField "recipient" "Address to receive unlocked funds (defaults to change address if omitted)"

-------------------------------------------------------------------------------

-- * Pass-through request types (thin wrappers, JSON only)

-------------------------------------------------------------------------------

-- | Accept a pending attestation.
data AcceptAttestationRequest = AcceptAttestationRequest
  { acrAttestationId :: GYAssetClass
  , acrUserAddresses :: UserAddresses
  , acrRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "acr", CamelToSnake]] AcceptAttestationRequest

instance ToSchema AcceptAttestationRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "acr") proxy
    return $ s
      & Swagger.schema . description ?~ "Countersign a pending attestation. Must be called by a wallet holding the subject profile's user token."
      & describeField "recipient" "Address to receive unlocked funds (defaults to change address if omitted)"

--------------------------------------------------------------------------------

-- | Bind a profile to a Cardano credential — __ADR 0003__.
--
-- Both parties consent in one appended record: the profile spends its user token and the credential
-- proves control of the same transaction. @credential@ is a CIP-129 identifier (@drep1…@,
-- @cc_cold1…@, @cc_hot1…@).
--
-- The name, description and image are the claim RECORD's own metadata — it is an attestation, so it
-- carries the same CIP-68 fields every other attestation does.
data ClaimCredentialRequest = ClaimCredentialRequest
  { cclProfileId :: GYAssetClass
  , cclCredential :: Text
  , cclWitness :: Maybe ClaimWitness
  , cclName :: Text
  , cclDescription :: Text
  , cclImageURI :: Text
  , cclUserAddresses :: UserAddresses
  , cclRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "ccl", CamelToSnake]] ClaimCredentialRequest

instance ToSchema ClaimCredentialRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "ccl") proxy
    return $
      s
        & Swagger.schema . description
          ?~ "Bind a profile to a Cardano credential, as an append-only record. Needs BOTH parties: \
             \the returned transaction spends the profile's user token and must be authorised by the \
             \credential as well. Costs a second transaction after /claim-profile, and buys a binding \
             \that can be ended by appending a withdrawal rather than by clearing a field."
        & describeField "credential" "CIP-129 identifier: drep1..., cc_cold1..., cc_hot1..."
        & describeField "witness" "How a SCRIPT credential proves control. Omit for a key credential: its signature on the returned transaction is the proof."
        & describeField "recipient" "Address to receive unlocked funds (defaults to change address if omitted)"

--------------------------------------------------------------------------------

-- | End a binding — __ADR 0003__, and the remedy of whoever's credential it is.
--
-- __Not the profile owner's route.__ The credential's proof alone authorises it, and the profile's
-- user token is deliberately not required: the case this exists for is a profile that claimed
-- somebody else's credential, and that token is held by whoever did it.
--
-- Nothing is erased. The claim stays in the log, this record is appended beside it, and the read
-- layer stops publishing the binding — so a malicious withdrawal costs a fee and leaves a visible
-- fact, where the field this replaces could be cleared for good.
data WithdrawCredentialRequest = WithdrawCredentialRequest
  { wclProfileId :: GYAssetClass
  , wclCredential :: Text
  , wclWitness :: Maybe ClaimWitness
  , wclName :: Text
  , wclDescription :: Text
  , wclImageURI :: Text
  , wclUserAddresses :: UserAddresses
  , wclRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "wcl", CamelToSnake]] WithdrawCredentialRequest

instance ToSchema WithdrawCredentialRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "wcl") proxy
    return $
      s
        & Swagger.schema . description
          ?~ "End a profile's binding to a credential. Authorised by the CREDENTIAL alone -- not by \
             \the profile's owner, who may be exactly the party that claimed a credential they do \
             \not control. Nothing is deleted: the claim stays on chain and this record is appended \
             \beside it, after which the read layer stops publishing the binding."
        & describeField "credential" "The CIP-129 identifier being withdrawn. A withdrawal naming a different credential than the profile currently publishes changes nothing."
        & describeField "witness" "How a SCRIPT credential proves control. Omit for a key credential."
        & describeField "recipient" "Address to receive unlocked funds (defaults to change address if omitted)"

-------------------------------------------------------------------------------

-- * Dispute request types

-------------------------------------------------------------------------------

-- | Contest an attestation. The dispute is its own UTxO pointing at the attestation, with its own
-- CIP-68 metadata — hence the name\/description\/image fields — and its own refundable deposit.
data OpenDisputeRequest = OpenDisputeRequest
  { odrAttestationId :: AttestationAC
  , odrOpenedByProfileId :: ProfileRefAC
  , odrDepositTo :: Maybe GYAddress
  , odrName :: Text
  , odrDescription :: Text
  , odrImageURI :: Text
  , odrUserAddresses :: UserAddresses
  , odrRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "odr", CamelToSnake]] OpenDisputeRequest

instance ToSchema OpenDisputeRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "odr") proxy
    return $ s
      -- The $ref-typed properties are described here rather than with `describeField`; see
      -- 'ClaimProfileRequest'.
      & Swagger.schema . description
        ?~ "Open a dispute against an attestation, locking the deposit the oracle currently \
           \requires. `attestation_id` is the attestation being contested and \
           \`opened_by_profile_id` the disputer, whose user token the wallet must hold. \
           \`deposit_to` is where the deposit returns on EITHER verdict. OMIT IT: it then defaults to \
           \the address holding the opener's user token, which is the one address the protocol is \
           \satisfied by for free, because spending that UTxO is how the opener authorises. If you do \
           \name one it must be an address you listed in `user_addresses` — an input from anywhere \
           \else would need that holder's signature, which nothing in this flow can produce, so it is \
           \refused as `DepositAddressNotSpendable` before anything is built rather than after you \
           \sign. A SCRIPT address is refused outright as `DepositAddressIsScript`: the refund is a \
           \plain output with no datum, which a script cannot spend, so it would be lost. `recipient` receives any unlocked funds and defaults to the change address."
      & describeField "name" "Dispute name"
      & describeField "description" "What is being contested, and why"
      & describeField "image_uri" "URI of the dispute image (the client hosts it; the protocol stores the URI)"

-- | Settle a dispute.
--
-- Reachable over HTTP although it is the admin who settles, unlike every @AdminActionType@
-- constructor: the oracle validator requires the admin's signature on chain, so this route can only
-- hand back an unsigned transaction — which is exactly the product here, a verdict a party asked for
-- and the admin then signs.
data ResolveDisputeRequest = ResolveDisputeRequest
  { rdrDisputeId :: GYAssetClass
  , rdrVerdict :: DisputeVerdict
  , rdrUserAddresses :: UserAddresses
  , rdrRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "rdr", CamelToSnake]] ResolveDisputeRequest

instance ToSchema ResolveDisputeRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "rdr") proxy
    return $ s
      -- Every property here is $ref-typed, so all of it is described at the schema level; see
      -- 'ClaimProfileRequest'.
      & Swagger.schema . description
        ?~ "Settle a dispute, naming it by `dispute_id`. Returns an UNSIGNED transaction: the oracle \
           \validator requires the admin's signature, so the admin signs what this route builds. \
           \`recipient` receives any unlocked funds and defaults to the change address."

--------------------------------------------------------------------------------

-- | Close an undecided dispute whose deadline has passed — D-A.
--
-- __The one write in this protocol that needs no authority.__ After a dispute's own deadline anyone
-- may close it, because an exit the oracle admin can gate — by pausing, or by holding the only key
-- — is not an exit, and an admin who does not act was the whole failure. There is nothing to gain:
-- the deposit returns to the address the opener named when they opened it.
data ExpireDisputeRequest = ExpireDisputeRequest
  { edrDisputeId :: GYAssetClass
  , edrUserAddresses :: UserAddresses
  , edrRecipient :: Maybe GYAddress
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "edr", CamelToSnake]] ExpireDisputeRequest

instance ToSchema ExpireDisputeRequest where
  declareNamedSchema proxy = do
    s <- genericDeclareNamedSchema (mkStripPrefixSchemaOptions "edr") proxy
    return $
      s
        & Swagger.schema . description
          ?~ "Close an undecided dispute whose deadline has passed, naming it by `dispute_id`. No \
             \verdict and no authority: the transaction this returns needs only a fee payer, and it \
             \records the dispute as `expired`, which is NOT a finding against either party. The \
             \deposit returns to the address the opener named. A dispute that is already decided, or \
             \whose deadline has not passed, is a 400."
        & describeField "recipient" "Address to receive unlocked funds (defaults to change address if omitted)"
