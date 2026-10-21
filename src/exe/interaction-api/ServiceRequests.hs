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
import Palmares.DomainTypes.Core.Types (AttestationType, ProfileRefAC)
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
  , iarAttestationDate :: GYTime
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
      & describeField "attestation_date""When the attestation is ISSUED. Must fall inside the transaction's validity window (roughly the next 7 hours of chain time), which is what makes it chain-attested."
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
