{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Palmares.DomainTypes.Core.Types where

import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.List.Extra
import Data.Swagger (NamedSchema (..), ToSchema (..), genericDeclareNamedSchema)
import Data.Swagger.Internal.Schema ()
import Data.Swagger.ParamSchema
import Data.Swagger.SchemaOptions (fromAesonOptions)
import Data.Text hiding (init, tail)
import Data.Text as T
import Database.Persist.TH
import Deriving.Aeson
import GHC.Generics ()
import GeniusYield.Types (GYAssetClass)
import GeniusYield.Types.Time
import Servant (FromHttpApiData (..))
import Palmares.Utils

type ProfileRefAC = GYAssetClass

type AchievementAC = GYAssetClass

-- | Profile type
data ProfileType = Practitioner | Organization
  deriving (Show, Generic, FromJSON, ToJSON, ToSchema, ToParamSchema, Eq, Ord)

derivePersistFieldJSON "ProfileType"

instance FromHttpApiData ProfileType where
  parseQueryParam :: Text -> Either Text ProfileType
  parseQueryParam = maybe (Left "Invalid profile type") Right . parseProfileType . T.unpack
    where
      parseProfileType s
        | s == "Practitioner" = Just Practitioner
        | s == "Organization" = Just Organization
        | otherwise = Nothing

-- | Profile
data Profile = Profile
  { profileId :: ProfileRefAC,
    profileName :: Text,
    profileDescription :: Text,
    profileImageURI :: Text,
    profileType :: ProfileType
  }
  deriving (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "profile", CamelToSnake]] Profile

derivePersistFieldJSON "Profile"

instance Show Profile where
  show :: Profile -> String
  show (Profile {..}) =
    Prelude.unlines
      [ "┌─────────────────────────────────────────────────────────────",
        "│ Name: " <> stringFromJSON profileName,
        "│ Description: " <> stringFromJSON profileDescription,
        "│ Image URI: " <> stringFromJSON profileImageURI,
        "│ ID: " <> stringFromJSON profileId,
        "└─────────────────────────────────────────────────────────────"
      ]

instance ToSchema Profile where
  declareNamedSchema = genericDeclareNamedSchema profileSchemaOptions
    where
      profileSchemaOptions :: SchemaOptions
      profileSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "profile"
            }

-- | JSON-serialized @[(Text, Text)]@ for achievement projections (array of @[key, value]@ string pairs).
newtype AchievementOtherMetadataJson = AchievementOtherMetadataJson
  { fromAchievementOtherMetadataJson :: [(Text, Text)]
  }
  deriving stock (Show, Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | An achievement awarded to a practitioner.
data Achievement = Achievement
  { achievementId :: AchievementAC,
    achievementAwardedToProfileId :: ProfileRefAC,
    achievementAwardedByProfileId :: ProfileRefAC,
    achievementAchievementDate :: GYTime,
    achievementAccepted :: Bool,
    achievementName :: Text,
    achievementDescription :: Text,
    achievementImageURI :: Text,
    achievementOtherMetadata :: [(Text, Text)],
    -- | On-chain pointer to the mint transaction (projected backend only; 'Nothing' on the live backend).
    achievementTxHash :: Maybe Text,
    achievementSlot :: Maybe Integer,
    achievementOutputIndex :: Maybe Int
  }
  deriving (Generic)
  deriving (ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievement", CamelToSnake]] Achievement

instance FromJSON Achievement where
  parseJSON = withObject "Achievement" $ \o ->
    Achievement
      <$> o .: "id"
      <*> o .: "awarded_to_profile_id"
      <*> o .: "awarded_by_profile_id"
      <*> o .: "achievement_date"
      <*> o .: "accepted"
      <*> o .: "name"
      <*> o .: "description"
      <*> o .: "image_uri"
      <*> o .:? "other_metadata" .!= []
      <*> o .:? "tx_hash"
      <*> o .:? "slot"
      <*> o .:? "output_index"

derivePersistFieldJSON "Achievement"
derivePersistFieldJSON "AchievementOtherMetadataJson"

instance Show Achievement where
  show :: Achievement -> String
  show (Achievement {..}) =
    Data.List.Extra.intercalate
      "\n"
      [ "┌─────────────────────────────────────────────────────────────",
        "│ Achievement ID: " <> stringFromJSON achievementId,
        "│ Name: " <> stringFromJSON achievementName,
        "│ Awarded To: " <> stringFromJSON achievementAwardedToProfileId,
        "│ Awarded By: " <> stringFromJSON achievementAwardedByProfileId,
        "│ Date: " <> stringFromJSON achievementAchievementDate,
        "│ Accepted: " <> show achievementAccepted,
        "│ Other metadata pairs: " <> show (Prelude.length achievementOtherMetadata),
        "└─────────────────────────────────────────────────────────────"
      ]

instance ToSchema Achievement where
  declareNamedSchema = genericDeclareNamedSchema achievementSchemaOptions
    where
      achievementSchemaOptions :: SchemaOptions
      achievementSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "achievement"
            }
