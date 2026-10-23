-- | Interaction dispatch: maps API-level 'Interaction' values to transaction skeletons
-- by delegating to the appropriate 'TxBuilding.Operations' functions.
module Palmares.TxBuilding.Interactions where

import Control.Monad.Reader.Class (MonadReader)
import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Bifunctor qualified
import Data.List.Extra
import Data.Maybe (fromMaybe)
import Data.Swagger (NamedSchema (..), Schema (..), ToSchema (..), defaultSchemaOptions, genericDeclareNamedSchema)
import Data.Swagger.Schema (SchemaOptions, fromAesonOptions)
import Deriving.Aeson
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types (AttestationType (CredentialClaim, CredentialWithdrawal))
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
  | DisputeAction DisputeActionType
  | ProtocolAction ProtocolActionType
  | AdminAction AdminActionType
  deriving (Show, Generic, FromJSON, ToJSON)

-- | Tagged, not constructor-keyed: 'taggedSumSchema' carries the measured defect and the mechanism.
-- This is the type @\/build-tx@ takes, so its published shape IS the request contract.
--
-- The one sentence added on top is about the admin arm. It is in the union and therefore in the tag
-- enum, and every request body carrying it is refused — which a tag enum on its own cannot say.
instance ToSchema ActionType where
  declareNamedSchema p = withAdminNote . taggedSumSchema <$> genericDeclareNamedSchema defaultSchemaOptions p
    where
      withAdminNote (NamedSchema n sch) =
        NamedSchema n sch {_schemaDescription = (<> adminNote) <$> _schemaDescription sch}
      adminNote =
        " The AdminAction arm is NOT accepted in a request body — it is a 400. Those actions are \
        \built and signed by the admin CLI, which holds the key the oracle validator requires."

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
        -- ADR 0003: a profile mint claims nothing. The two credential actions below are the binding.
        ClaimProfileAction kind profileData ->
          claimProfileTX
            (profileTypeToOnchainProfileKind kind)
            (profileDataToMetadataFields profileData)
        -- The binding, and its end. Both go through one builder; the kind is what decides whether
        -- the profile's own user token is spent, because a withdrawal must not ask for it.
        --
        -- `usedAddrs` is passed either way and used only on a claim — the builder decides, not this
        -- call site, so the rule lives in one place.
        ClaimCredentialAction profileRefAC credText mWitness profileData -> do
          -- Resolved before any chain query, so a pasted-wrong identifier is a 400 and not a timeout.
          credential <- either (throwError . GYApplicationException) return (parseClaimCredential credText)
          credentialAttestationTX
            (attestationTypeToOnchainAttestationKind CredentialClaim)
            profileRefAC
            credential
            mWitness
            (profileDataToMetadataFields profileData)
            usedAddrs
        WithdrawCredentialAction profileRefAC credText mWitness profileData -> do
          credential <- either (throwError . GYApplicationException) return (parseClaimCredential credText)
          credentialAttestationTX
            (attestationTypeToOnchainAttestationKind CredentialWithdrawal)
            profileRefAC
            credential
            mWitness
            (profileDataToMetadataFields profileData)
            usedAddrs
        IssueAttestationAction subjectId issuerId kind profileData otherMeta claimedPeriod -> do
          let otherMetadataPlutus = map (Data.Bifunctor.bimap textToBuiltinByteString textToBuiltinByteString) otherMeta
          issueAttestationTX
            subjectId
            issuerId
            (attestationTypeToOnchainAttestationKind kind)
            (profileDataToMetadataFields profileData)
            otherMetadataPlutus
            (fmap (Data.Bifunctor.bimap timeToPlutus timeToPlutus) claimedPeriod)
            usedAddrs
        AcceptAttestationAction attestationId -> do
          skeleton <- acceptAttestationTX attestationId usedAddrs
          return (skeleton, attestationId)
    DisputeAction disputeActionType -> case disputeActionType of
      OpenDisputeAction targetId openerId mDepositTo profileData ->
        fmap (fmap Just) $
          openDisputeTX
            targetId
            openerId
            -- The deposit returns to the change address unless the disputer named another: a
            -- validator cannot resolve a profile id into an address, so SOME address has to be in
            -- the datum, and the wallet that paid is the only sensible default.
            (fromMaybe (changeAddress userAddresses) mDepositTo)
            (profileDataToMetadataFields profileData)
            usedAddrs
      ResolveDisputeAction disputeId verdict -> do
        skeleton <- resolveDisputeTX disputeId (disputeVerdictToOnchainVerdict verdict)
        return (skeleton, Just disputeId)
      -- No verdict argument and no signer: the caller does not choose the outcome here, the clock
      -- does. See 'Palmares.TxBuilding.Operations.expireDisputeTX'.
      ExpireDisputeAction disputeId -> do
        skeleton <- expireDisputeTX disputeId
        return (skeleton, Just disputeId)
    ProtocolAction protocolActionType -> case protocolActionType of
      CleanupDustAction -> do
        (skeleton, _dustCount) <- cleanupDustTX
        return (skeleton, Nothing)
    AdminAction adminActionType -> do
      skeleton <- updateOracleTX adminActionType
      return (skeleton, Nothing)
