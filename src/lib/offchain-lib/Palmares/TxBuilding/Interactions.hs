-- | Interaction dispatch: maps API-level 'Interaction' values to transaction skeletons
-- by delegating to the appropriate 'TxBuilding.Operations' functions.
module Palmares.TxBuilding.Interactions where

import Control.Monad.Reader.Class (MonadReader)
import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Bifunctor qualified
import Data.List.Extra
import Data.Swagger (NamedSchema (..), Schema (..), ToSchema (..), defaultSchemaOptions, genericDeclareNamedSchema)
import Data.Swagger.Schema (SchemaOptions, fromAesonOptions)
import Deriving.Aeson
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types (AttestationType (CredentialClaim, CredentialWithdrawal), parseLevelOneAnchor)
import GHC.Stack (HasCallStack)
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.TxBuilding.Context (DeployedScriptsContext)
import Palmares.TxBuilding.Conversions
import Palmares.TxBuilding.Exceptions (TxBuildingException (AttestationAnchorMalformed))
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
  | -- | The second field is how the CURRENT admin proves control of 'OracleParams.opAdmin' — ADR
    -- 0005 made it a 'Credential', so for a native multisig the proof is a spent input and the
    -- witness says how to spend it. 'Nothing' is a key admin, whose proof is a signature, and that
    -- is every deployment until somebody rotates.
    --
    -- On the wrapper rather than inside each 'AdminActionType' constructor because it is a property
    -- of WHO is acting, not of WHICH action: all eight need it identically. The rotation actions
    -- carry a second witness of their own, for the incoming side, which is a different question.
    --
    -- Carrying it costs this arm nothing in the published API: every 'AdminActionType' constructor
    -- is refused over HTTP by its own 'FromJSON', so this field is only ever filled by the CLI.
    AdminAction AdminActionType (Maybe ClaimWitness)
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
      -- The first sentence used to come from the generator, which named each arm's payload type.
      -- It stopped naming this one when ADR 0005 gave the arm a second field: aeson then wraps the
      -- pair in a `contents` ARRAY and swagger2 emits no `$ref` for the generator to read. Said
      -- here instead, because a published contract that silently drops a type name is worse than
      -- one that spells it out — and this arm is refused anyway, so nothing depends on the shape.
      adminNote =
        " The AdminAction arm carries [AdminActionType, ClaimWitness or null] — the action, and how \
        \the current admin proves control of a script credential (ADR 0005). It is NOT accepted in \
        \a request body — it is a 400. Those actions are built and signed by the admin CLI, which \
        \holds the credential the oracle validator requires."

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
          -- The level-1 anchor — __ADR 0008__. Checked HERE, before the metadata becomes
          -- `BuiltinByteString`, because the anchor's two values are bech32 TEXT and validating them
          -- after the conversion would mean decoding bytes back into text that was text a moment
          -- ago. This is the shared root for `/issue-attestation` and `/build-tx` alike, which is why
          -- it is not in a handler: nothing on chain validates the anchor — by the specification's
          -- own decision, since a treasury withdrawal is not an addressable UTxO — so this is the
          -- last point at which a bad pointer is a 400 instead of a permanent record the read layer
          -- has to publish as `malformed`.
          case parseLevelOneAnchor otherMeta of
            Left why -> throwError (GYApplicationException (AttestationAnchorMalformed why))
            Right _ -> return ()
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
            -- Passed through, NOT defaulted here — OF-02. The default belongs in the builder
            -- because only the builder knows which address holds the opener's user NFT, and that is
            -- the one address @Md8@ is satisfied by for free. Defaulting to the CHANGE address here
            -- is what broke multi-address wallets: a change address need not be an input.
            mDepositTo
            (profileDataToMetadataFields profileData)
            usedAddrs
      -- `Nothing` for the arbiter's witness, deliberately: a script arbiter resolving over HTTP
      -- would have to supply one, and that is a JSON field on `ResolveDisputeAction` which can be
      -- added later without breaking a client, because it is optional. The datum format could not
      -- be. So the split is taken now and this half is left until somebody rotates `opArbiter` to a
      -- script; until then every arbiter is a key, whose proof is a signature and needs no witness.
      -- A script arbiter can resolve today through the admin CLI, which does pass one.
      ResolveDisputeAction disputeId verdict -> do
        skeleton <- resolveDisputeTX disputeId (disputeVerdictToOnchainVerdict verdict) Nothing
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
    AdminAction adminActionType mAdminWitness -> do
      skeleton <- updateOracleTX adminActionType mAdminWitness
      return (skeleton, Nothing)
