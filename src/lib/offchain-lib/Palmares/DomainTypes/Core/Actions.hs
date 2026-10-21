{-# OPTIONS_GHC -Wno-partial-fields #-}

module Palmares.DomainTypes.Core.Actions where

import Control.Lens ((&), (?~))
import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.List.Extra
import Data.Proxy (Proxy (..))
import Data.Swagger
  ( NamedSchema (..),
    SwaggerType (SwaggerObject),
    ToSchema (..),
    description,
    genericDeclareNamedSchema,
    type_,
  )
import Data.Swagger.Internal.Schema ()
import Data.Swagger.ParamSchema
import Data.Swagger.SchemaOptions (fromAesonOptions)
import Data.Text hiding (init, tail)
import Data.Text.Encoding qualified as TE
import Deriving.Aeson
import Palmares.DomainTypes.Core.Types
import GHC.Generics ()
import GeniusYield.Types
  ( GYAddress,
    GYAssetClass,
    GYPubKeyHash,
    GYRedeemer,
    GYScript,
    GYSimpleScript,
    GYTime,
    PlutusVersion (PlutusV3),
    datumFromPlutus',
    datumToPlutus',
    redeemerFromPlutus',
    redeemerToPlutus',
    scriptFromCBOR,
    scriptToSerialisedScript,
  )
import Palmares.Onchain.Protocol.Types (FeeConfig)

-------------------------------------------------------------------------------

-- * Actions

-------------------------------------------------------------------------------

data ProfileData
  = ProfileData
  { profileDataName :: Text,
    profileDataDescription :: Text,
    profileDataImageURI :: Text
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "profileData", CamelToSnake]] ProfileData

instance ToSchema ProfileData where
  declareNamedSchema = genericDeclareNamedSchema profileDataSchemaOptions
    where
      -- Schema options that match the JSON field modifiers
      profileDataSchemaOptions :: SchemaOptions
      profileDataSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "profileData"
            }

-- | How a claimant proves control of the credential it claims: the witness the ledger needs in order
-- to spend the input that proof rests on.
--
-- __This is what makes a script a first-class issuer.__ Authority in this protocol is token
-- possession and not a signature list, so an organisation or a committee acting through a script has
-- to be able to say how its input is spent. 'WitnessKey' is the ordinary wallet case, and it is what
-- 'Palmares.TxBuilding.Skeletons.txMustSpendFromAddress' used to hardcode for every path.
--
-- The wire form is tagged — @{"tag":"key"}@, @{"tag":"simple_script","script":…}@,
-- @{"tag":"plutus_script","script":"\<cbor hex\>","redeemer":…}@ — and hand-written rather than
-- derived, because neither @GYScript@ nor @GYRedeemer@ carries a JSON instance.
data ClaimWitness
  = -- | An ordinary key witness: the claiming wallet signs.
    WitnessKey
  | -- | A native (timelock or multisig) script. It takes no redeemer: the ledger checks it, and there
    -- is nothing for a validator to inspect — which is exactly why control is proven by the spend
    -- rather than re-derived on chain.
    WitnessSimpleScript GYSimpleScript
  | -- | A Plutus script and the redeemer it expects, both supplied by the caller. A script that holds
    -- no UTxO at its own address cannot claim in one transaction, however good the witness — see
    -- 'Palmares.TxBuilding.Exceptions.ScriptCredentialHasNoUtxo'.
    WitnessPlutusScript (GYScript 'PlutusV3) GYRedeemer
  deriving stock (Show)

instance ToJSON ClaimWitness where
  toJSON WitnessKey = object ["tag" .= ("key" :: Text)]
  toJSON (WitnessSimpleScript s) = object ["tag" .= ("simple_script" :: Text), "script" .= s]
  toJSON (WitnessPlutusScript sc r) =
    object
      [ "tag" .= ("plutus_script" :: Text),
        "script" .= scriptCborHex sc,
        "redeemer" .= datumFromPlutus' (redeemerToPlutus' r)
      ]

instance FromJSON ClaimWitness where
  parseJSON = withObject "ClaimWitness" $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "key" -> pure WitnessKey
      "simple_script" -> WitnessSimpleScript <$> o .: "script"
      "plutus_script" -> do
        hex <- o .: "script"
        sc <- maybe (fail "ClaimWitness: script is not the CBOR hex of a PlutusV3 script") pure (scriptFromCBOR hex)
        WitnessPlutusScript sc . redeemerFromPlutus' . datumToPlutus' <$> o .: "redeemer"
      _ -> fail "ClaimWitness: tag must be one of key, simple_script, plutus_script"

-- | A compiled script as the CBOR hex 'scriptFromCBOR' reads back — the inverse of that function.
scriptCborHex :: GYScript 'PlutusV3 -> Text
scriptCborHex = TE.decodeUtf8 . B16.encode . SBS.fromShort . scriptToSerialisedScript

-- | Hand-written, and an OBJECT rather than the string 'AdminActionType' declares: a derived
-- instance is impossible here (no @ToSchema@ for @GYScript@ or @GYRedeemer@) and a @string@ would
-- document a body the API rejects, which is the defect 'Palmares.DomainTypes.Core.Types.AttestationType'
-- was measured shipping. The three shapes go in the description, where a reader can act on them.
instance ToSchema ClaimWitness where
  declareNamedSchema _ =
    pure $
      NamedSchema (Just "ClaimWitness") $
        mempty
          & type_ ?~ SwaggerObject
          & description
            ?~ "How control of the claimed credential is proven. One of {\"tag\": \"key\"}, \
               \{\"tag\": \"simple_script\", \"script\": <native script>}, or \
               \{\"tag\": \"plutus_script\", \"script\": \"<script CBOR hex>\", \"redeemer\": <script data>}."

-- NOTE: DeleteProfileAction is intentionally not supported to preserve lineage integrity.
-- An attestation record is a permanent historical fact and must stay resolvable.
data ProfileActionType
  = UpdateProfileAction
      { profile_id :: ProfileRefAC,
        new_desc :: Maybe Text,
        image_uri :: Text
      }
  | -- | Mint a profile, optionally claiming a Cardano credential.
    --
    -- The claim is the spec's one sentence: /prove you can spend as that credential/. @cp_credential@
    -- is a CIP-129 identifier (@drep1…@, @cc_cold1…@, @cc_hot1…@) and @cp_witness@ says how the
    -- proving input is spent; both are 'Nothing' for a profile that corresponds to no on-chain
    -- credential — a Community or an Auditor — which the read layer presents as @unclaimed@ rather
    -- than verified.
    ClaimProfileAction
      { cp_kind :: ProfileType,
        cp_credential :: Maybe Text,
        cp_witness :: Maybe ClaimWitness,
        cp_profile_data :: ProfileData
      }
  | IssueAttestationAction
      { aa_subject_profile_id :: ProfileRefAC,
        aa_issuer_profile_id :: ProfileRefAC,
        aa_kind :: AttestationType,
        aa_profile_data :: ProfileData,
        aa_other_metadata :: [(Text, Text)],
        -- | The claimed period, self-reported. Optional, and both bounds or neither.
        --
        -- The issuance date is deliberately NOT a field beside this one. It is derived from the chain
        -- tip, because the minting policy requires it to fall inside the transaction's validity
        -- interval (@Ml@, inherited fix #4) and that interval is built from the tip — so a
        -- client-supplied date could only ever agree with it or be refused. This field is the one
        -- that can say something about the past, and it is published as a claim.
        aa_claimed_period :: Maybe (GYTime, GYTime)
      }
  | AcceptAttestationAction
      { aca_attestation_id :: GYAssetClass
      }
  deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

-------------------------------------------------------------------------------

-- * Dispute Actions

-------------------------------------------------------------------------------

-- | Contesting an attestation, and settling the contest.
--
-- Its own action type rather than two more arms on 'ProfileActionType', because a dispute is its own
-- UTxO pointing at an attestation and never a field on one — the same separation the on-chain layer
-- makes, which is what keeps the attestation path's ExUnits unchanged.
--
-- __'ResolveDisputeAction' is reachable over HTTP, unlike every 'AdminActionType' constructor__, and
-- that is safe for the reason the admin actions are not: the oracle validator requires the admin's
-- signature on chain, so the server can only ever hand back an unsigned transaction that the admin's
-- own key must then sign.
data DisputeActionType
  = OpenDisputeAction
      { od_attestation_id :: AttestationAC,
        od_opened_by_profile_id :: ProfileRefAC,
        -- | Where the deposit returns, on either verdict. Defaults to the change address when
        -- omitted. A validator cannot resolve a profile id into an address, so the disputer names
        -- one; pointing it somewhere useless costs only the disputer.
        od_deposit_to :: Maybe GYAddress,
        od_profile_data :: ProfileData
      }
  | ResolveDisputeAction
      { rd_dispute_id :: GYAssetClass,
        rd_verdict :: DisputeVerdict
      }
  deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

-------------------------------------------------------------------------------

-- * Protocol Actions (permissionless maintenance)

-------------------------------------------------------------------------------

-- | Protocol-level maintenance actions that any user can trigger.
-- These do not require admin privileges and are available via the REST API.
data ProtocolActionType
  = -- | Permissionless cleanup of dust/griefing UTxOs at validator addresses.
    -- Anyone can call this — the recovered ADA goes to the caller.
    CleanupDustAction
  deriving (Show, Generic, FromJSON, ToJSON, ToSchema)

-------------------------------------------------------------------------------

-- * Admin Actions (oracle management)

-------------------------------------------------------------------------------

-- | Admin actions for managing protocol parameters via the oracle.
-- These modify the oracle UTxO datum and require the admin signing key.
--
-- Note: These actions are only constructed programmatically (admin CLI),
-- never deserialized from JSON. The ToJSON/FromJSON/ToSchema instances
-- are minimal stubs required because ActionType is embedded in Interaction
-- which needs full JSON support for the REST API.
data AdminActionType
  = PauseProtocolAction
  | UnpauseProtocolAction
  | -- | Nothing = clear fees, Just fc = set fees
    SetFeesAction (Maybe FeeConfig)
  | -- | Minimum lovelace for protocol state outputs (oracle opMinUTxOValue)
    SetMinUTxOValueAction Integer
  | -- | Hand the oracle to a new admin — inherited fix #2.
    --
    -- Deliberately NOT deserializable from an HTTP body (see the 'FromJSON' instance below): an
    -- action that changes who controls the protocol must come from the admin CLI, where the key that
    -- has to sign it already lives.
    RotateAdminAction GYPubKeyHash
  | -- | Lovelace a NEW dispute must deposit (oracle opDisputeDeposit).
    --
    -- Reachable over HTTP, like 'SetMinUTxOValueAction' and unlike 'RotateAdminAction': repricing a
    -- refundable deposit cannot hand the protocol to anyone, and it still needs the admin signature
    -- the oracle validator requires. It cannot touch a dispute already open — that deposit is
    -- recorded in the dispute's own datum.
    SetDisputeDepositAction Integer
  deriving (Show, Generic)

instance ToJSON AdminActionType where
  toJSON PauseProtocolAction = object ["tag" .= ("PauseProtocolAction" :: Text)]
  toJSON UnpauseProtocolAction = object ["tag" .= ("UnpauseProtocolAction" :: Text)]
  toJSON (SetFeesAction _) = object ["tag" .= ("SetFeesAction" :: Text)]
  toJSON (SetMinUTxOValueAction n) = object ["tag" .= ("SetMinUTxOValueAction" :: Text), "lovelace" .= n]
  -- The new admin's hash is deliberately NOT serialized: this instance exists for logging and for
  -- echoing an action back, and a rotation's log line has no business carrying the key.
  toJSON (RotateAdminAction _) = object ["tag" .= ("RotateAdminAction" :: Text)]
  toJSON (SetDisputeDepositAction n) = object ["tag" .= ("SetDisputeDepositAction" :: Text), "lovelace" .= n]

instance FromJSON AdminActionType where
  parseJSON = withObject "AdminActionType" $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "PauseProtocolAction" -> pure PauseProtocolAction
      "UnpauseProtocolAction" -> pure UnpauseProtocolAction
      "SetMinUTxOValueAction" -> SetMinUTxOValueAction <$> o .: "lovelace"
      "SetDisputeDepositAction" -> SetDisputeDepositAction <$> o .: "lovelace"
      _ -> fail "AdminActionType: unsupported action for JSON deserialization"

instance ToSchema AdminActionType where
  declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy Text)
