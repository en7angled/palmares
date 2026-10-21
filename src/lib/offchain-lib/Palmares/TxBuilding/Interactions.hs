-- | Interaction dispatch: maps API-level 'Interaction' values to transaction skeletons
-- by delegating to the appropriate 'TxBuilding.Operations' functions.
module Palmares.TxBuilding.Interactions where

import Control.Monad.Reader.Class (MonadReader)
import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Bifunctor qualified
import Data.List.Extra
import Data.Swagger (ToSchema (..), genericDeclareNamedSchema)
import Data.Swagger.Schema (SchemaOptions, fromAesonOptions)
import Deriving.Aeson
import Palmares.DomainTypes.Core.Actions
import GHC.Stack (HasCallStack)
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.TxBuilding.Context (DeployedScriptsContext)
import Palmares.TxBuilding.Conversions
import Palmares.TxBuilding.Operations

------------------------------------------------------------------------------------------------

-- * Types

------------------------------------------------------------------------------------------------

-- | Input parameters to add for reference script.
data AddWitAndSubmitParams = AddWitAndSubmitParams
  { awasTxUnsigned :: !GYTx,
    awasTxWit :: !GYTxWitness
  }
  deriving (Generic)
  deriving (FromJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "awas", CamelToSnake]] AddWitAndSubmitParams

instance ToSchema AddWitAndSubmitParams where
  declareNamedSchema = genericDeclareNamedSchema addWitAndSubmitParamsSchemaOptions
    where
      addWitAndSubmitParamsSchemaOptions :: SchemaOptions
      addWitAndSubmitParamsSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "awas"
            }

data UserAddresses = UserAddresses
  { -- | User's used addresses.
    usedAddresses :: [GYAddress],
    -- | User's change address.
    changeAddress :: GYAddress,
    -- | Browser wallet's reserved collateral (if set).
    reservedCollateral :: Maybe GYTxOutRefCbor
  }
  deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

data ActionType
  = ProfileAction ProfileActionType
  | ProtocolAction ProtocolActionType
  | AdminAction AdminActionType
  deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

data Interaction
  = Interaction
  { -- | The intended action to perform.
    action :: ActionType,
    -- | The user addresses to be used as input for transaction building.
    userAddresses :: UserAddresses,
    -- | If the interaction unlocks some funds, the funds will be sent to this address (if set, otherwise to the change address).
    recipient :: Maybe GYAddress
  }
  deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

-- | Dispatch an 'Interaction' to the corresponding operation, producing a tx skeleton
-- and optionally the asset class of the newly minted or consumed token.
interactionToTxSkeleton ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  Interaction ->
  m (GYTxSkeleton 'PlutusV3, Maybe GYAssetClass)
interactionToTxSkeleton Interaction {..} = do
  let usedAddrs = usedAddresses userAddresses
  case action of
    ProfileAction actionType -> do
      fmap (fmap Just) $ case actionType of
        UpdateProfileAction profileRefAC mbDesc imgURI -> do
          (,profileRefAC)
            <$> updateProfileTX
              profileRefAC
              (textToBuiltinByteString <$> mbDesc)
              (textToBuiltinByteString imgURI)
              usedAddrs
        IssueAttestationAction subjectId issuerId profileData otherMeta attestationDate -> do
          let otherMetadataPlutus = map (Data.Bifunctor.bimap textToBuiltinByteString textToBuiltinByteString) otherMeta
          issueAttestationTX subjectId issuerId (profileDataToMetadataFields profileData) otherMetadataPlutus (timeToPlutus attestationDate) usedAddrs
        AcceptAttestationAction attestationId -> do
          skeleton <- acceptAttestationTX attestationId usedAddrs
          return (skeleton, attestationId)
    ProtocolAction protocolActionType -> case protocolActionType of
      CleanupDustAction -> do
        (skeleton, _dustCount) <- cleanupDustTX
        return (skeleton, Nothing)
    AdminAction adminActionType -> do
      skeleton <- updateOracleTX adminActionType
      return (skeleton, Nothing)
