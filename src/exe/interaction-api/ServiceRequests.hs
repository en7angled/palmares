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

-- | Mint a profile, optionally claiming a Cardano credential.
--
-- @credential@ and @witness@ travel together: a profile that claims a credential must say how the
-- input proving control of it is spent. Both omitted is the unclaimed profile — a Community or an
-- Auditor — which the read layer presents as @unclaimed@ rather than verified.
data ClaimProfileRequest = ClaimProfileRequest
  { cprKind :: ProfileType
  , cprCredential :: Maybe Text
  , cprWitness :: Maybe ClaimWitness
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
      -- `recipient`, `kind` and `witness` are described HERE and not with `describeField`, because
      -- each of those properties is a bare `$ref` and a Swagger 2.0 $ref cannot carry a sibling
      -- description — measured: the key is simply absent from the generated document. Same reason
      -- `IssueAttestationRequest` below has no `describeField "kind"`.
      & Swagger.schema . description
        ?~ "Mint a profile, optionally claiming a Cardano credential. `recipient` receives any \
           \unlocked funds and defaults to the change address. `witness` says how the input that \
           \proves control of `credential` is spent; both are omitted for an unclaimed profile."
      & describeField "credential" "CIP-129 credential identifier being claimed (drep1…, cc_cold1…, cc_hot1…). Omit for a profile that corresponds to no on-chain credential. A CIP-105 id is refused: it carries no header byte, so it cannot say key or script."
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
           \`deposit_to` is where the deposit returns on EITHER verdict and defaults to the change \
           \address: a validator cannot resolve a profile id into an address, so the disputer names \
           \one, and pointing it somewhere useless costs only the disputer. `recipient` receives any \
           \unlocked funds and also defaults to the change address."
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
