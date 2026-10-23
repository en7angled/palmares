{-# OPTIONS_GHC -Wno-partial-fields #-}

module Palmares.DomainTypes.Core.Actions where

import Control.Lens ((&), (.~), (?~), (^.), at, itoList)
import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.List.Extra
import Data.Swagger
  ( NamedSchema (..),
    Reference (..),
    Referenced (..),
    SwaggerType (..),
    ToSchema (..),
    description,
    enum_,
    genericDeclareNamedSchema,
    properties,
    required,
    type_,
  )
import Data.Swagger.Internal.Schema ()
import Data.Swagger.ParamSchema
-- `defaultSchemaOptions` is in scope from the unqualified 'Data.Swagger.ParamSchema' above.
import Data.Swagger.SchemaOptions (fromAesonOptions)
import Data.Text hiding (init, tail)
import Data.Text qualified as T
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

-------------------------------------------------------------------------------

-- * The sum types' published schema

-------------------------------------------------------------------------------

-- | Rewrite @swagger2@'s generic sum-type schema into the tagged object aeson actually accepts.
--
-- __The defect this exists for, measured.__ @swagger2@'s 'Data.Swagger.SchemaOptions' has no
-- @sumEncoding@ field, so its generic 'ToSchema' always publishes a CONSTRUCTOR-KEYED object —
-- @{"\<ConstructorName\>": {…}}@ with @maxProperties: 1@ — while aeson's derived 'FromJSON' for the
-- same type reads a @TaggedObject@: @{"tag": "\<ConstructorName\>", …fields inlined}@. The committed
-- @docs\/generated\/swagger\/interaction-swagger-api.json@ carried the constructor-keyed shape for
-- @ActionType@ and 'ProfileActionType', so a client that followed the published document got a 400
-- on every write. Same class of defect as the derived enum schema
-- 'Palmares.DomainTypes.Core.Types.AttestationType' shipped with, and the same remedy: the document
-- must describe the values the API accepts.
--
-- __Why it takes the generic schema apart instead of replacing it.__ The tag enum and the field list
-- come from the constructors themselves, so adding an arm updates the document and there is no
-- hand-maintained table to forget. That is the whole anti-drift mechanism —
-- @UnitTests.InteractionApi@ pins it from the other side by encoding a value of each arm and
-- requiring every key it emits to be a documented property.
--
-- __What Swagger 2.0 cannot say.__ There is no @oneOf@, so WHICH fields go with which tag is not
-- expressible structurally: the per-arm shapes go in the description, where a reader can act on
-- them, and only @tag@ (plus @contents@, when every arm carries one) stays required. The
-- 'ClaimWitness' instance above makes the same trade for the same reason.
--
-- Two notes on the result. Fields of different arms that share a name collapse into one property —
-- none do today, every arm's fields are prefixed — and an arm with no fields of its own is an arm
-- aeson wraps in @contents@, which is how it is documented.
taggedSumSchema :: NamedSchema -> NamedSchema
taggedSumSchema (NamedSchema name s) =
  NamedSchema name $
    mempty
      & type_ ?~ SwaggerObject
      & properties .~ (tagProperty <> inlinedFields <> contentsProperty)
      & required .~ requiredKeys
      & description ?~ maybe shapes (\d -> d <> " " <> shapes) (s ^. description)
  where
    -- One entry per constructor: the key is the constructor name, the value is the schema swagger2
    -- generated for that arm.
    arms = itoList (s ^. properties)

    -- A record arm's own fields; empty for an arm aeson wraps in @contents@ (swagger2 gives those a
    -- @$ref@ or a scalar schema, neither of which has properties).
    fieldsOf (Inline sub) = sub ^. properties
    fieldsOf (Ref _) = mempty

    keysOf = fmap fst . itoList . fieldsOf

    payloadArms = [a | a <- arms, Prelude.null (keysOf (snd a))]

    tagProperty =
      mempty
        & at "tag"
          ?~ Inline
            ( mempty
                & type_ ?~ SwaggerString
                & enum_ ?~ fmap (String . fst) arms
                & description ?~ "Which arm of the union this object is."
            )

    inlinedFields = mconcat (fmap (fieldsOf . snd) arms)

    contentsProperty
      | Prelude.null payloadArms = mempty
      | otherwise =
          mempty
            & at "contents"
              ?~ Inline
                ( mempty
                    & description ?~ "The arm's payload. Its schema depends on \"tag\" — see the shapes in this schema's description."
                )

    -- `contents` is required only when EVERY arm carries one; a union that mixes record arms with
    -- payload arms has no field that is required by all of them except the tag.
    requiredKeys
      | not (Prelude.null arms), Prelude.length payloadArms == Prelude.length arms = ["tag", "contents"]
      | otherwise = ["tag"]

    shapes =
      "A TAGGED object, not a constructor-keyed one: the arm's name is in \"tag\" and its own fields \
      \sit beside it. Shapes: "
        <> T.intercalate "; " (fmap shapeOf arms)
        <> "."

    shapeOf (con, r) = con <> ": " <> case (keysOf r, r) of
      ([], Ref (Reference n)) -> "\"contents\" is " <> n
      ([], _) -> "\"contents\""
      (ks, _) -> T.intercalate ", " ks

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
        -- interval (@Mq@, inherited fix #4) and that interval is built from the tip — so a
        -- client-supplied date could only ever agree with it or be refused. This field is the one
        -- that can say something about the past, and it is published as a claim.
        aa_claimed_period :: Maybe (GYTime, GYTime)
      }
  | AcceptAttestationAction
      { aca_attestation_id :: GYAssetClass
      }
  deriving (Show, Generic, FromJSON, ToJSON)

-- | Tagged, not constructor-keyed — see 'taggedSumSchema' for the defect this fixes.
instance ToSchema ProfileActionType where
  declareNamedSchema p = taggedSumSchema <$> genericDeclareNamedSchema defaultSchemaOptions p

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
        -- one.
        --
        -- __This used to say "pointing it somewhere useless costs only the disputer". It does
        -- not.__ Resolution pays this address with @txOutAddress == disputeDepositTo@, so an address
        -- no real output can carry makes @D4@ unsatisfiable and the dispute UNRESOLVABLE — left open
        -- against its target forever, for the price of one deposit. The cost falls on the subject of
        -- the attestation, not on the disputer, which is what made this a griefing vector rather
        -- than a foot-gun. @Md8@ now requires the address to be one the opening transaction spends
        -- from.
        od_deposit_to :: Maybe GYAddress,
        od_profile_data :: ProfileData
      }
  | ResolveDisputeAction
      { rd_dispute_id :: GYAssetClass,
        rd_verdict :: DisputeVerdict
      }
  | -- | Close an undecided dispute whose deadline has passed — D-A.
    --
    -- __Permissionless, and that is the point.__ It takes no verdict and no authority: after the
    -- dispute's own @disputeStaleAfter@ the chain lets anyone close it as @expired@, because an
    -- escape hatch the admin could gate — by pausing, or by holding the only key — is not an escape
    -- hatch. The deposit returns to the address the opener named, so a stranger who builds this
    -- transaction pays the fee and keeps nothing.
    --
    -- Reachable over HTTP for the same reason @ResolveDisputeAction@ is, and more so: there is no
    -- signature to wait for, so the service can build it for whoever asks.
    ExpireDisputeAction
      { ed_dispute_id :: GYAssetClass
      }
  deriving (Show, Generic, FromJSON, ToJSON)

-- | Tagged, not constructor-keyed — see 'taggedSumSchema' for the defect this fixes.
instance ToSchema DisputeActionType where
  declareNamedSchema p = taggedSumSchema <$> genericDeclareNamedSchema defaultSchemaOptions p

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
-- __None of them is reachable over HTTP.__ Every constructor's 'FromJSON' fails, so an admin action
-- cannot arrive in a request body — not through a dedicated route, which does not exist, and not
-- through @\/build-tx@, which takes an @ActionType@ and used to accept four of these from any
-- Basic-auth holder.
--
-- The reasoning, because this is a behaviour change on a route that exists: the oracle validator
-- requires the admin's signature on chain, so a server can only ever hand back an UNSIGNED
-- transaction. HTTP therefore buys the admin nothing — the @admin@ CLI already builds and signs in
-- one step, with the key that has to sign it — while the parsers left a credential holder able to
-- make the server build a protocol-pause transaction, spend provider calls doing it, and present the
-- result as something to sign. A surface with no use and a non-zero cost comes off.
--
-- 'Palmares.DomainTypes.Core.Actions.DisputeActionType'\'s @ResolveDisputeAction@ is the deliberate
-- contrast: it IS reachable over HTTP and needs the admin's signature just the same, because there
-- the unsigned transaction is the product — a verdict a disputing party asked for, built by the
-- service and signed by the admin.
--
-- The 'ToJSON' instance stays: it is used for logging and for echoing an action back, and
-- @ActionType@ needs it to have one. 'ToSchema' stays and says the refusal.
data AdminActionType
  = PauseProtocolAction
  | UnpauseProtocolAction
  | -- | Nothing = clear fees, Just fc = set fees
    SetFeesAction (Maybe FeeConfig)
  | -- | Minimum lovelace for protocol state outputs (oracle opMinUTxOValue)
    SetMinUTxOValueAction Integer
  | -- | Hand the oracle to a new admin — inherited fix #2.
    RotateAdminAction GYPubKeyHash
  | -- | Lovelace a NEW dispute must deposit (oracle opDisputeDeposit).
    --
    -- It cannot touch a dispute already open — that deposit is recorded in the dispute's own datum.
    SetDisputeDepositAction Integer
  | -- | Milliseconds a NEW dispute may sit undecided before anyone may close it (oracle
    -- @opDisputeTimeoutMs@) — D-A.
    --
    -- Like the deposit above, it cannot touch a dispute already open: that deadline is recorded in
    -- the dispute's own datum at open time, precisely so that an admin cannot postpone it.
    SetDisputeTimeoutAction Integer
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
  toJSON (SetDisputeTimeoutAction ms) = object ["tag" .= ("SetDisputeTimeoutAction" :: Text), "milliseconds" .= ms]

-- | Always fails — see the type's Haddock. The message is a 400 body a client reads, so it says
-- where the action belongs rather than only that it was refused.
instance FromJSON AdminActionType where
  parseJSON _ =
    fail
      "AdminActionType: admin actions are not accepted over HTTP. The oracle validator requires the \
      \admin's signature, so this service could only ever return an unsigned transaction; build and \
      \sign it with the admin CLI, which holds that key."

-- | A named schema, so the refusal is IN the published document: the generated @ActionType@ schema
-- @$ref@s this one, and a reader following the reference finds out that the arm exists and is
-- rejected. It was previously 'Text' — unnamed, hence inlined as a bare @{"type":"string"}@, which
-- documented the arm as something a client could send.
instance ToSchema AdminActionType where
  declareNamedSchema _ =
    pure $
      NamedSchema (Just "AdminActionType") $
        mempty
          & type_ ?~ SwaggerObject
          & description
            ?~ "NOT ACCEPTED OVER HTTP — every request body carrying an admin action is a 400. These \
               \actions change oracle parameters and the oracle validator requires the admin's \
               \signature, so a service can only ever return an unsigned transaction; they are built \
               \and signed by the admin CLI. Listed because the action union has an arm for them."
