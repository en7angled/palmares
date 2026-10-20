{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Wire response types for the query API that include @thumbnail_uri@. Domain
-- types in offchain-lib store image URIs only; this module maps to JSON and
-- derives thumbnails via a query-local helper (today @image_uri@; may later
-- resolve cached or CDN URLs).
--
-- JSON uses @StripPrefix@ + @CamelToSnake@ (see 'ProfileResponse', 'LineageGraphData').
module Palmares.DomainTypes.Transfer.QueryResponses
  ( ProfileResponse (..),
    AchievementResponse (..),
    OrganizationProfileResponse (..),
    profileToResponse,
    achievementToResponse,
    organizationProfileToResponse,
    SearchResults (..),
    SearchGroup (..),
    SearchHit (..),
    SearchTarget (..),
    LineageGraphData (..),
    LineageNode (..),
    LineageEdge (..),
    AchievementInformationResponse (..),
    achievementInformationToResponse,
    AchievementsMonthlyStatsResponse (..),
    AchievementsPageResponse (..),
    ProfilesPageResponse (..),
    OrganizationExplorerPageResponse (..),
    TopOrganizationResponse (..),
    topOrganizationResponse,
    ActivityEventDetails (..),
    ActivityEventResponse (..),
  )
where

import Data.Swagger (ToSchema (..), genericDeclareNamedSchema)
import Data.Swagger.Internal.Schema ()
import Data.Text (Text)
import Deriving.Aeson
import Palmares.DomainTypes.Core.Types qualified as Core
import Palmares.DomainTypes.Transfer.OrderBy (ActivityEventType (..))
import Palmares.DomainTypes.Transfer.Types qualified as T
import GeniusYield.Types (GYTime)
import Palmares.Utils (mkStripPrefixSchemaOptions)

-- * Profile

data ProfileResponse = ProfileResponse
  { profileId :: Core.ProfileRefAC,
    profileName :: Text,
    profileDescription :: Text,
    profileImageURI :: Text,
    profileThumbnailURI :: Text,
    profileType :: Core.ProfileType
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "profile", CamelToSnake]] ProfileResponse

instance ToSchema ProfileResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "profile")

profileToResponse :: Core.Profile -> ProfileResponse
profileToResponse p =
  ProfileResponse
    { profileId = Core.profileId p,
      profileName = Core.profileName p,
      profileDescription = Core.profileDescription p,
      profileImageURI = Core.profileImageURI p,
      profileThumbnailURI = deriveThumbnailUri (Core.profileImageURI p),
      profileType = Core.profileType p
    }

-- * Achievement

data AchievementResponse = AchievementResponse
  { achievementId :: Core.AchievementAC,
    achievementAwardedToProfileId :: Core.ProfileRefAC,
    achievementAwardedByProfileId :: Core.ProfileRefAC,
    achievementAchievementDate :: GYTime,
    achievementAccepted :: Bool,
    achievementName :: Text,
    achievementDescription :: Text,
    achievementImageURI :: Text,
    achievementThumbnailURI :: Text,
    achievementOtherMetadata :: [(Text, Text)],
    achievementTxHash :: Maybe Text,
    achievementSlot :: Maybe Integer,
    achievementOutputIndex :: Maybe Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievement", CamelToSnake]] AchievementResponse

instance ToSchema AchievementResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievement")

achievementToResponse :: Core.Achievement -> AchievementResponse
achievementToResponse a =
  AchievementResponse
    { achievementId = Core.achievementId a,
      achievementAwardedToProfileId = Core.achievementAwardedToProfileId a,
      achievementAwardedByProfileId = Core.achievementAwardedByProfileId a,
      achievementAchievementDate = Core.achievementAchievementDate a,
      achievementAccepted = Core.achievementAccepted a,
      achievementName = Core.achievementName a,
      achievementDescription = Core.achievementDescription a,
      achievementImageURI = Core.achievementImageURI a,
      achievementThumbnailURI = deriveThumbnailUri (Core.achievementImageURI a),
      achievementOtherMetadata = Core.achievementOtherMetadata a,
      achievementTxHash = Core.achievementTxHash a,
      achievementSlot = Core.achievementSlot a,
      achievementOutputIndex = Core.achievementOutputIndex a
    }

-- | Enriched achievement with resolved profile information for awarded-to and awarded-by.
-- Both profiles use 'ProfileResponse' (which carries 'profileType') because either
-- practitioners or organizations can award/receive achievements.
data AchievementInformationResponse = AchievementInformationResponse
  { achievementInfoId :: Core.AchievementAC,
    achievementInfoAchievementDate :: GYTime,
    achievementInfoAccepted :: Bool,
    achievementInfoName :: Text,
    achievementInfoDescription :: Text,
    achievementInfoImageURI :: Text,
    achievementInfoThumbnailURI :: Text,
    achievementInfoOtherMetadata :: [(Text, Text)],
    achievementInfoTxHash :: Maybe Text,
    achievementInfoSlot :: Maybe Integer,
    achievementInfoOutputIndex :: Maybe Int,
    achievementInfoAwardedTo :: ProfileResponse,
    achievementInfoAwardedBy :: ProfileResponse
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievementInfo", CamelToSnake]] AchievementInformationResponse

instance ToSchema AchievementInformationResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievementInfo")

achievementInformationToResponse ::
  Core.Profile ->
  Core.Profile ->
  Core.Achievement ->
  AchievementInformationResponse
achievementInformationToResponse awardedTo awardedBy a =
  AchievementInformationResponse
    { achievementInfoId = Core.achievementId a,
      achievementInfoAchievementDate = Core.achievementAchievementDate a,
      achievementInfoAccepted = Core.achievementAccepted a,
      achievementInfoName = Core.achievementName a,
      achievementInfoDescription = Core.achievementDescription a,
      achievementInfoImageURI = Core.achievementImageURI a,
      achievementInfoThumbnailURI = deriveThumbnailUri (Core.achievementImageURI a),
      achievementInfoOtherMetadata = Core.achievementOtherMetadata a,
      achievementInfoTxHash = Core.achievementTxHash a,
      achievementInfoSlot = Core.achievementSlot a,
      achievementInfoOutputIndex = Core.achievementOutputIndex a,
      achievementInfoAwardedTo = profileToResponse awardedTo,
      achievementInfoAwardedBy = profileToResponse awardedBy
    }

data OrganizationProfileResponse = OrganizationProfileResponse
  { organizationId :: Core.ProfileRefAC,
    organizationName :: Text,
    organizationDescription :: Text,
    organizationImageURI :: Text,
    organizationThumbnailURI :: Text
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "organization", CamelToSnake]] OrganizationProfileResponse

instance ToSchema OrganizationProfileResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "organization")

organizationProfileToResponse :: T.OrganizationProfileInformation -> OrganizationProfileResponse
organizationProfileToResponse o =
  OrganizationProfileResponse
    { organizationId = T.organizationId o,
      organizationName = T.organizationName o,
      organizationDescription = T.organizationDescription o,
      organizationImageURI = T.organizationImageURI o,
      organizationThumbnailURI = deriveThumbnailUri (T.organizationImageURI o)
    }

-- * Unified search (snake_case JSON per backend-api-requirements §9)

data SearchResults = SearchResults
  { searchResultsQuery :: Text,
    searchResultsTotal :: Int,
    searchResultsPractitioners :: SearchGroup,
    searchResultsOrganizations :: SearchGroup,
    searchResultsAchievements :: SearchGroup
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchResults", CamelToSnake]] SearchResults

instance ToSchema SearchResults where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchResults")

data SearchGroup = SearchGroup
  { searchGroupTotal :: Int,
    searchGroupItems :: [SearchHit]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchGroup", CamelToSnake]] SearchGroup

instance ToSchema SearchGroup where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchGroup")

data SearchHit = SearchHit
  { searchHitId :: Text,
    searchHitTitle :: Text,
    searchHitSubtitle :: Text,
    searchHitBadges :: [Text],
    searchHitStatus :: Maybe Text,
    searchHitTarget :: SearchTarget
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchHit", CamelToSnake]] SearchHit

instance ToSchema SearchHit where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchHit")

data SearchTarget = SearchTarget
  { searchTargetKind :: Text,
    searchTargetId :: Text
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchTarget", CamelToSnake]] SearchTarget

instance ToSchema SearchTarget where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchTarget")

-- * Lineage graph (snake_case JSON per backend-api-requirements §10)

data LineageGraphData = LineageGraphData
  { lineageGraphDataNodes :: [LineageNode],
    lineageGraphDataEdges :: [LineageEdge]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "lineageGraphData", CamelToSnake]] LineageGraphData

instance ToSchema LineageGraphData where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "lineageGraphData")

data LineageNode = LineageNode
  { lineageNodeProfileId :: Core.ProfileRefAC,
    lineageNodeName :: Text,
    lineageNodeImageUri :: Text,
    lineageNodeThumbnailUri :: Text,
    lineageNodeProfileType :: Core.ProfileType
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "lineageNode", CamelToSnake]] LineageNode

instance ToSchema LineageNode where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "lineageNode")

data LineageEdge = LineageEdge
  { lineageEdgeFrom :: Core.ProfileRefAC,
    lineageEdgeTo :: Core.ProfileRefAC,
    lineageEdgeDate :: GYTime
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "lineageEdge", CamelToSnake]] LineageEdge

instance ToSchema LineageEdge where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "lineageEdge")

-- * Explorer page aggregates (backend-api-requirements §12.5)

-- | Accepted vs pending achievement counts per calendar month.
data AchievementsMonthlyStatsResponse = AchievementsMonthlyStatsResponse
  { achievementsMonthlyStatsMonth :: Text,
    achievementsMonthlyStatsAccepted :: Int,
    achievementsMonthlyStatsPending :: Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievementsMonthlyStats", CamelToSnake]] AchievementsMonthlyStatsResponse

instance ToSchema AchievementsMonthlyStatsResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievementsMonthlyStats")

data AchievementsPageResponse = AchievementsPageResponse
  { achievementsPageItems :: [AchievementResponse],
    achievementsPageTotal :: Int,
    achievementsPageMonthly :: [AchievementsMonthlyStatsResponse]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievementsPage", CamelToSnake]] AchievementsPageResponse

instance ToSchema AchievementsPageResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievementsPage")

data ProfilesPageResponse = ProfilesPageResponse
  { profilesPageItems :: [ProfileResponse],
    profilesPageTotal :: Int,
    profilesPageFrequency :: [(Core.ProfileType, Int)]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "profilesPage", CamelToSnake]] ProfilesPageResponse

instance ToSchema ProfilesPageResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "profilesPage")

-- | Organization explorer page: one page of organization profiles + total.
-- Collapses the frontend's per-row @GET \/organization\/{id}@ (N+1) into a
-- single response, mirroring 'PractitionerExplorerPageResponse'.
data OrganizationExplorerPageResponse = OrganizationExplorerPageResponse
  { organizationExplorerPageItems :: [OrganizationProfileResponse],
    organizationExplorerPageTotal :: Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "organizationExplorerPage", CamelToSnake]] OrganizationExplorerPageResponse

instance ToSchema OrganizationExplorerPageResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "organizationExplorerPage")

-- * §12.1 Dashboard

-- | Top organization by active member count.
data TopOrganizationResponse = TopOrganizationResponse
  { topOrganizationOrganization :: OrganizationProfileResponse,
    topOrganizationMemberCount :: Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "topOrganization", CamelToSnake]] TopOrganizationResponse

instance ToSchema TopOrganizationResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "topOrganization")

-- | Build a 'TopOrganizationResponse' from an org profile response and member count.
topOrganizationResponse :: OrganizationProfileResponse -> Int -> TopOrganizationResponse
topOrganizationResponse org count =
  TopOrganizationResponse
    { topOrganizationOrganization = org,
      topOrganizationMemberCount = count
    }

-- * Activity feed (§ activity endpoint)

-- | Human-readable context for an activity event.
data ActivityEventDetails = ActivityEventDetails
  { activityEventDetailsTitle :: Text,
    activityEventDetailsBody :: Maybe Text,
    activityEventDetailsActorName :: Maybe Text,
    activityEventDetailsTargetName :: Maybe Text
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "activityEventDetails", CamelToSnake]] ActivityEventDetails

instance ToSchema ActivityEventDetails where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "activityEventDetails")

-- | Single activity feed item.
data ActivityEventResponse = ActivityEventResponse
  { activityEventEventType :: ActivityEventType,
    activityEventActorId :: Core.ProfileRefAC,
    activityEventTargetId :: Maybe Core.ProfileRefAC,
    activityEventTimestamp :: GYTime,
    activityEventDetails :: ActivityEventDetails
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "activityEvent", CamelToSnake]] ActivityEventResponse

instance ToSchema ActivityEventResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "activityEvent")

-- | Derive the thumbnail URL shown in API responses from an image URI.
-- Today mirrors @image_uri@; may later resolve cached or CDN URLs.
deriveThumbnailUri :: Text -> Text
deriveThumbnailUri = id
