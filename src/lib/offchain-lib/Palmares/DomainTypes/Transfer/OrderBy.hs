{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}

module Palmares.DomainTypes.Transfer.OrderBy where

import Control.Lens
import Data.Aeson
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.List.Extra
import Data.Swagger
import Data.Swagger.Internal.Schema ()
import Data.Text hiding (init, tail)
import Data.Text qualified as T
import Deriving.Aeson
import GHC.Generics ()
import GeniusYield.Types (GYAddress, addressFromTextMaybe)
import Palmares.Utils (jsonEnumParamSchema, parseJsonEnumParam)
import Servant (FromHttpApiData (..))

data SortOrder = Asc | Desc
  deriving (Show, Generic, Eq)

instance ToSchema SortOrder where
  declareNamedSchema = genericDeclareNamedSchema sortOrderSchemaOptions
    where
      sortOrderSchemaOptions :: SchemaOptions
      sortOrderSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.constructorTagModifier = camelTo2 '_' . dropPrefix "SortOrder"
            }

instance ToParamSchema SortOrder where
  toParamSchema _ =
    mempty
      & type_
        ?~ SwaggerString
      & enum_
        ?~ [Aeson.String (T.pack "asc"), Aeson.String (T.pack "desc")]

data ProfilesOrderBy
  = ProfilesOrderById
  | ProfilesOrderByName
  | ProfilesOrderByDescription
  | ProfilesOrderByType
  | ProfilesOrderByRegisteredAt
  deriving (Show, Generic, Eq)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "ProfilesOrderBy", CamelToSnake]] ProfilesOrderBy

instance ToParamSchema ProfilesOrderBy where
  toParamSchema _ =
    mempty
      & type_
        ?~ SwaggerString
      & enum_
        ?~ [ Aeson.String (T.pack "id"),
             Aeson.String (T.pack "name"),
             Aeson.String (T.pack "description"),
             Aeson.String (T.pack "type"),
             Aeson.String (T.pack "registered_at")
           ]

instance ToSchema ProfilesOrderBy where
  declareNamedSchema = genericDeclareNamedSchema profilesOrderBySchemaOptions
    where
      profilesOrderBySchemaOptions :: SchemaOptions
      profilesOrderBySchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.constructorTagModifier = camelTo2 '_' . dropPrefix "ProfilesOrderBy"
            }

instance FromHttpApiData SortOrder where
  parseQueryParam :: Text -> Either Text SortOrder
  parseQueryParam t =
    case T.toLower t of
      "asc" -> Right Asc
      "desc" -> Right Desc
      _ -> Left "Invalid sort order. Use 'asc' or 'desc'"

instance FromHttpApiData ProfilesOrderBy where
  parseQueryParam :: Text -> Either Text ProfilesOrderBy
  parseQueryParam t =
    case T.toLower t of
      "name" -> Right ProfilesOrderByName
      "id" -> Right ProfilesOrderById
      "description" -> Right ProfilesOrderByDescription
      "type" -> Right ProfilesOrderByType
      "registered_at" -> Right ProfilesOrderByRegisteredAt
      _ -> Left "Invalid order by. Use 'name', 'id', 'description', 'type', or 'registered_at'"

data AttestationsOrderBy
  = AttestationsOrderById
  | AttestationsOrderByDate
  | AttestationsOrderBySubject
  | AttestationsOrderByIssuer
  | AttestationsOrderByName
  deriving (Show, Generic, Eq)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "AttestationsOrderBy", CamelToSnake]] AttestationsOrderBy

instance ToSchema AttestationsOrderBy where
  declareNamedSchema = genericDeclareNamedSchema attestationsOrderBySchemaOptions
    where
      attestationsOrderBySchemaOptions :: SchemaOptions
      attestationsOrderBySchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.constructorTagModifier = camelTo2 '_' . dropPrefix "AttestationsOrderBy"
            }

instance ToParamSchema AttestationsOrderBy where
  toParamSchema _ =
    mempty
      & type_
        ?~ SwaggerString
      & enum_
        ?~ [ Aeson.String (T.pack "id"),
             Aeson.String (T.pack "date"),
             Aeson.String (T.pack "issued_to"),
             Aeson.String (T.pack "issued_by"),
             Aeson.String (T.pack "name")
           ]

instance FromHttpApiData AttestationsOrderBy where
  parseQueryParam t =
    case T.toLower t of
      "id" -> Right AttestationsOrderById
      "date" -> Right AttestationsOrderByDate
      "issued_to" -> Right AttestationsOrderBySubject
      "issued_by" -> Right AttestationsOrderByIssuer
      "name" -> Right AttestationsOrderByName
      _ -> Left "Invalid order by. Use 'id', 'date', 'issued_to', 'issued_by', or 'name'"

-- | Newtype for wallet address URL capture (bech32 encoded).
newtype WalletAddress = WalletAddress {unWalletAddress :: GYAddress}

instance FromHttpApiData WalletAddress where
  parseUrlPiece t = case addressFromTextMaybe t of
    Just addr -> Right (WalletAddress addr)
    Nothing -> Left "Invalid bech32 wallet address"

instance ToParamSchema WalletAddress where
  toParamSchema _ =
    mempty
      & type_
        ?~ SwaggerString

instance ToSchema WalletAddress where
  declareNamedSchema _ = do
    return $
      NamedSchema (Just "WalletAddress") $
        mempty
          & type_ ?~ SwaggerString
          & description ?~ "Bech32-encoded Cardano address"
          & example ?~ toJSON (T.pack "addr_test1...")

-- ---------------------------------------------------------------------------------------------

-- * Governance orderings

--
-- Each of these is a CLOSED enum, and that is the security property: 'Query.Common.SortSpec'
-- splices a column name straight into an @ORDER BY@, and the only way a column name gets there
-- is through a total function from one of these types. No request text reaches the clause.
--
-- The Swagger @enum@ and the query parser are both read out of 'toJSON' by
-- 'Palmares.Utils.jsonEnumParamSchema' and 'Palmares.Utils.parseJsonEnumParam', so the documented
-- values and the accepted values are the same list.

-- | @order_by@ on @GET \/dreps@. Default is @voting_power@, descending: every DRep list is a
-- leaderboard, and ascending-by-id would bury the DReps a delegator is looking for.
data DRepsOrderBy
  = DRepsOrderById
  | DRepsOrderByVotingPower
  | DRepsOrderByDelegatorCount
  | DRepsOrderByParticipationRate
  | DRepsOrderByRationaleRate
  | DRepsOrderByRegisteredAt
  | DRepsOrderByVotesCast
  | DRepsOrderByName
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[StripPrefix "DRepsOrderBy", CamelToSnake]] DRepsOrderBy

instance ToParamSchema DRepsOrderBy where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData DRepsOrderBy where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

-- | @order_by@ on @GET \/drep\/{id}\/delegators@. Default is @lovelace@, descending: the question
-- the list answers is who backs this DRep, and that is a question about weight.
data DelegatorsOrderBy
  = DelegatorsOrderByLovelace
  | DelegatorsOrderByDelegatedAt
  | DelegatorsOrderByStakeAddress
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[StripPrefix "DelegatorsOrderBy", CamelToSnake]] DelegatorsOrderBy

instance ToParamSchema DelegatorsOrderBy where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData DelegatorsOrderBy where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

-- | @order_by@ on @GET \/gov-actions@. Default is @proposed_at@, descending: the question a
-- governance list answers first is what is happening now.
data GovActionsOrderBy
  = GovActionsOrderByProposedAt
  | GovActionsOrderByExpiresEpoch
  | GovActionsOrderByType
  | GovActionsOrderByDeposit
  | GovActionsOrderByTreasuryAmount
  | GovActionsOrderByVotesCast
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[StripPrefix "GovActionsOrderBy", CamelToSnake]] GovActionsOrderBy

instance ToParamSchema GovActionsOrderBy where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData GovActionsOrderBy where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

-- | @order_by@ on @GET \/votes@. Default is @cast_at@, descending: a vote feed is a chronology.
data VotesOrderBy
  = VotesOrderByCastAt
  | VotesOrderByVotingPower
  | VotesOrderByLatency
  | VotesOrderByVoterId
  | VotesOrderByGovActionId
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[StripPrefix "VotesOrderBy", CamelToSnake]] VotesOrderBy

instance ToParamSchema VotesOrderBy where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData VotesOrderBy where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

-- | @order_by@ on @GET \/delegations@. Default is @at@, descending: a delegation list read without
-- a filter is a feed of what just moved.
data DelegationsOrderBy
  = DelegationsOrderByAt
  | DelegationsOrderByLovelace
  | DelegationsOrderByStakeAddress
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[StripPrefix "DelegationsOrderBy", CamelToSnake]] DelegationsOrderBy

instance ToParamSchema DelegationsOrderBy where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData DelegationsOrderBy where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

-- | @order_by@ on @GET \/spos@. Default is @voting_power@, descending: like @\/dreps@, this list is
-- a distribution and the question it answers first is who holds the weight.
data SPOsOrderBy
  = SPOsOrderByVotingPower
  | SPOsOrderByVotesCast
  | SPOsOrderByPoolId
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[StripPrefix "SPOsOrderBy", CamelToSnake]] SPOsOrderBy

instance ToParamSchema SPOsOrderBy where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData SPOsOrderBy where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

-- | @order_by@ on @GET \/treasury-withdrawals@. Default is @enacted_epoch@, descending.
--
-- On preprod that ordering is entirely NULL — no withdrawal has ever been enacted — so the page
-- is decided by the tiebreaker. That is the right default anyway, and it is the reason the
-- tiebreaker has to be total: see 'Query.Gov.withdrawalSortSpec'.
data TreasuryWithdrawalsOrderBy
  = TreasuryWithdrawalsOrderByAmount
  | TreasuryWithdrawalsOrderByEnactedEpoch
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON
          '[ConstructorTagModifier '[StripPrefix "TreasuryWithdrawalsOrderBy", CamelToSnake]]
          TreasuryWithdrawalsOrderBy

instance ToParamSchema TreasuryWithdrawalsOrderBy where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData TreasuryWithdrawalsOrderBy where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

