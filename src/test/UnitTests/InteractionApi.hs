{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The interaction API's surface: what it serves, what it accepts, and what it publishes.
--
-- Three things are pinned here, and each one failed before T-ATTEST-7.
--
-- 1. __The published document contradicted the wire format.__ @swagger2@'s @SchemaOptions@ has no
--    @sumEncoding@ field, so its generic 'Data.Swagger.ToSchema' always emits a constructor-keyed
--    object — @{"\<ConstructorName\>": {…}}@ with @maxProperties: 1@ — while aeson's derived
--    'Data.Aeson.FromJSON' reads a @TaggedObject@. A client that followed
--    @docs\/generated\/swagger\/interaction-swagger-api.json@ got a 400 on every write. The fix is
--    'Palmares.DomainTypes.Core.Actions.taggedSumSchema'; the pin is the encoder itself — every arm
--    is encoded and every key it emits must be a documented property.
--
-- 2. __Admin actions were reachable over HTTP.__ @AdminActionType@'s 'Data.Aeson.FromJSON' accepted
--    four of its six constructors from a request body, so a Basic-auth holder could have the server
--    build a protocol-pause transaction through @\/build-tx@. Every constructor is refused now.
--
-- 3. __The served route set and the committed document.__ The document is generated from the API
--    type by @interaction-api --write-swagger-only@ and committed; the routes, the title, the
--    version and @\/status@\'s fields are asserted against it. It is therefore the drift gate a
--    reader already expects from @UnitTests.MetricDoc@: change the API and this fails until the
--    document is regenerated.
--
-- __Why not the API type itself.__ A cabal test-suite cannot import an executable's other-modules,
-- and the suite's @hs-source-dirs@ already carries @src\/exe\/query-api@ — whose @RestAPI@ would
-- shadow interaction-api's module of the same name. The generated document is the only view of the
-- served routes available from here, which is a second reason to gate on it.
module UnitTests.InteractionApi (interactionApiTests) where

import Control.Lens (at, itoList, (^.))
import Data.Aeson
  ( Result (..),
    ToJSON,
    Value (..),
    eitherDecodeFileStrict,
    fromJSON,
    toJSON,
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Swagger (Referenced (Inline), Schema, ToSchema, enum_, maxProperties, properties, toSchema)
import Data.Text (Text)
import GeniusYield.Types (GYAssetClass, GYPubKeyHash, pubKeyHashToPlutus)
import PlutusLedgerApi.V3 (Credential (PubKeyCredential))
import Palmares.ChainSync.KupoAtlas (toGYAssetClass)
import Palmares.DomainTypes.Core.Actions
  ( AdminActionType (..),
    DisputeActionType (..),
    ProfileActionType (..),
    ProfileData (..),
    ProtocolActionType (..),
  )
import Palmares.DomainTypes.Core.Types (AttestationType (Affiliation), DisputeVerdict (VerdictUpheld), ProfileType (PersonDRep))
import Palmares.TxBuilding.Interactions (ActionType (..))
import Test.Tasty
import Test.Tasty.HUnit

-------------------------------------------------------------------------------

-- * Fixtures

-------------------------------------------------------------------------------

ac :: Text -> GYAssetClass
ac t = either (error "bad asset class fixture") id (toGYAssetClass t)

pd :: ProfileData
pd = ProfileData "a name" "a description" "ipfs://image"

-- | 28 bytes, which is what a key hash is.
pkhA :: GYPubKeyHash
pkhA = "11111111111111111111111111111111111111111111111111111111"

-- | One value per constructor. The lists are what make the schema assertions exhaustive, so a new
-- arm costs one line here — and nothing else notices it.
profileArms :: [ProfileActionType]
profileArms =
  [ UpdateProfileAction (ac "00000000000000000000000000000000000000000000000000000000.6161") (Just "new") "ipfs://i",
    ClaimProfileAction PersonDRep pd,
    IssueAttestationAction
      (ac "00000000000000000000000000000000000000000000000000000000.6262")
      (ac "00000000000000000000000000000000000000000000000000000000.6363")
      Affiliation
      pd
      [("source", "self-reported")]
      Nothing,
    AcceptAttestationAction (ac "00000000000000000000000000000000000000000000000000000000.6464")
  ]

disputeArms :: [DisputeActionType]
disputeArms =
  [ OpenDisputeAction
      (ac "00000000000000000000000000000000000000000000000000000000.6565")
      (ac "00000000000000000000000000000000000000000000000000000000.6666")
      Nothing
      pd,
    ResolveDisputeAction (ac "00000000000000000000000000000000000000000000000000000000.6767") VerdictUpheld
  ]

-- | The admin arm is deliberately absent: 'adminBodies' covers it, and it is the one arm that must
-- NOT parse back.
nonAdminActionArms :: [ActionType]
nonAdminActionArms = map ProfileAction profileArms <> map DisputeAction disputeArms

-- | One per constructor, so the assertion is about the TYPE and not about the four arms that used
-- to parse. 'RotateArbiterAction' is here for the same reason: an admin action absent from this
-- list is an admin action nobody has checked is refused over HTTP.
adminActions :: [AdminActionType]
adminActions =
  [ PauseProtocolAction,
    UnpauseProtocolAction,
    SetFeesAction Nothing,
    SetMinUTxOValueAction 1_000_000,
    RotateAdminAction (PubKeyCredential (pubKeyHashToPlutus pkhA)) Nothing,
    SetDisputeDepositAction 5_000_000,
    RotateArbiterAction (PubKeyCredential (pubKeyHashToPlutus pkhA)) Nothing
  ]

-- | Request bodies built by the ENCODERS of the types under test, never hand-spelled. A hand-written
-- @{"tag": …}@ that happened to be the wrong shape would be refused for the wrong reason and the
-- assertion would pass vacuously; a body the server's own 'Data.Aeson.ToJSON' produced cannot be.
adminBodies :: [Value]
adminBodies = map toJSON adminActions

-- | The same actions as they reach @\/build-tx@: wrapped in the arm of the union that route takes.
adminArms :: [Value]
adminArms = map (toJSON . (`AdminAction` Nothing)) adminActions

-------------------------------------------------------------------------------

-- * Helpers

-------------------------------------------------------------------------------

propKeys :: Schema -> [Text]
propKeys s = map fst (itoList (s ^. properties))

-- | The values the schema says @tag@ may take.
tagEnum :: Schema -> [Value]
tagEnum s = case s ^. properties . at "tag" of
  Just (Inline t) -> fromMaybe [] (t ^. enum_)
  _ -> []

objKeys :: Value -> [Text]
objKeys (Object o) = map Key.toText (KeyMap.keys o)
objKeys _ = []

field :: Text -> Value -> Maybe Value
field k (Object o) = KeyMap.lookup (Key.fromText k) o
field _ _ = Nothing

path :: [Text] -> Value -> Maybe Value
path ks v = foldl (\acc k -> acc >>= field k) (Just v) ks

-------------------------------------------------------------------------------

-- * The tests

-------------------------------------------------------------------------------

swaggerPath :: FilePath
swaggerPath = "docs/generated/swagger/interaction-swagger-api.json"

interactionApiTests :: TestTree
interactionApiTests =
  testGroup
    "interaction API surface"
    [ ---- the published schema is the wire format ------------------------------------------------
      testCase "ProfileActionType publishes a TAGGED object, not a constructor-keyed one" $ do
        let s = toSchema (Proxy @ProfileActionType)
        assertBool "tag is a property" ("tag" `elem` propKeys s)
        -- `maxProperties: 1` is the fingerprint of swagger2's constructor-keyed sum encoding, and
        -- the constructor names as PROPERTY keys are the other half of it.
        assertEqual "no maxProperties" Nothing (s ^. maxProperties)
        assertEqual
          "no property is named after a constructor"
          []
          (filter (`elem` propKeys s) ["UpdateProfileAction", "ClaimProfileAction", "IssueAttestationAction", "AcceptAttestationAction"]),
      testCase "DisputeActionType and ActionType publish tagged objects too" $
        assertEqual
          "tag is a property of both"
          [True, True]
          [ "tag" `elem` propKeys (toSchema (Proxy @DisputeActionType)),
            "tag" `elem` propKeys (toSchema (Proxy @ActionType))
          ],
      -- The anti-drift half, and the one that makes the instances honest rather than merely
      -- different: the encoder is the authority. Every key a value emits must be documented, and the
      -- tag it emits must be one the document lists.
      testCase "every arm encodes within its own published schema" $
        mapM_ armIsDocumented armChecks,
      ---- the admin surface is off HTTP ----------------------------------------------------------
      testCase "no admin action deserializes from an HTTP body" $
        map adminParses adminBodies @?= replicate (length adminBodies) (Left ()),
      -- The hole was at THIS level: /build-tx takes an ActionType, and its AdminAction arm parsed
      -- four of the six admin actions straight out of a request body.
      testCase "/build-tx cannot carry an admin action either" $
        map actionParses adminArms @?= replicate (length adminArms) (Left ()),
      -- The guard on the guard. If ActionType's FromJSON broke outright, every case above would
      -- still pass and the whole write surface would be gone.
      testCase "the arms that are meant to parse still do" $
        map (actionParses . toJSON) nonAdminActionArms @?= replicate (length nonAdminActionArms) (Right ()),
      ---- the committed document ------------------------------------------------------------------
      --
      -- DEVIATION from the plan's list, which named /swagger-ui and /swagger-api.json and omitted
      -- /update-profile. The two Swagger-UI paths are served by `SwaggerSchemaUI` and are not in the
      -- document by construction — `PublicAPI` excludes them — and /update-profile has existed since
      -- T-ATTEST-6. The captured path is spelled the way Swagger spells it.
      -- RENAMED from "every write action has a typed route", which is what the project WANTS but not
      -- what this case checks: it pins the path set, so a write action added without a route leaves
      -- it green. D-A and D-E added two such actions and this case said nothing — the invariant in
      -- the old name is maintained by hand, and naming the case after the stronger claim is the same
      -- mistake this repo keeps finding in its comments.
      testCase "the published path set is exactly this" $ do
        doc <- readSwagger
        sort (objKeys (fromMaybe Null (field "paths" doc)))
          @?= [ "/accept-attestation",
                "/build-tx",
                "/claim-credential",
                "/claim-profile",
                "/expire-dispute",
                "/health",
                "/issue-attestation",
                "/open-dispute",
                "/ready",
                "/resolve-dispute",
                "/status",
                "/submit-tx",
                "/tx-status/{txId}",
                "/update-profile",
                "/withdraw-credential"
              ],
      -- /health answers `alwaysHealthy` and reports healthy with a dead provider and unreachable
      -- scripts. /status is what an operator actually needs.
      testCase "/status reports the provider, the deployed scripts and the oracle's paused flag" $ do
        doc <- readSwagger
        sort (objKeys (fromMaybe Null (path ["definitions", "InteractionStatusResponse", "properties"] doc)))
          @?= ["deployed_scripts", "network", "oracle_paused", "provider", "version"],
      testCase "the Swagger title and version name this product" $ do
        doc <- readSwagger
        (path ["info", "title"] doc, path ["info", "version"] doc)
          @?= (Just (String "Palmares Interaction API"), Just (String "3.3.0")),
      -- The same defect as the first case, asserted on the artifact a client actually downloads.
      -- This is the one that was measured: both definitions carried `maxProperties: 1`.
      testCase "the published action definitions are tagged objects" $ do
        doc <- readSwagger
        let defn n = fromMaybe Null (path ["definitions", n] doc)
        [ (field "maxProperties" (defn n), "tag" `elem` objKeys (fromMaybe Null (field "properties" (defn n))))
          | n <- ["ActionType", "ProfileActionType", "DisputeActionType"]
          ]
          @?= replicate 3 (Nothing, True)
    ]
  where
    readSwagger = do
      r <- eitherDecodeFileStrict swaggerPath
      case r of
        Left e ->
          assertFailure $
            swaggerPath
              <> ": "
              <> e
              <> " — regenerate it with `cabal run exe:interaction-api -- --write-swagger-only`."
        Right v -> pure (v :: Value)

    adminParses v = case fromJSON v :: Result AdminActionType of
      Success _ -> Right ()
      Error _ -> Left ()

    actionParses v = case fromJSON v :: Result ActionType of
      Success _ -> Right ()
      Error _ -> Left ()

    armChecks =
      checksFor "ProfileActionType" profileArms
        <> checksFor "DisputeActionType" disputeArms
        <> checksFor "ActionType" (nonAdminActionArms <> [ProtocolAction CleanupDustAction, AdminAction PauseProtocolAction Nothing])

    checksFor :: forall a. (ToSchema a, ToJSON a) => String -> [a] -> [(String, Schema, Value)]
    checksFor name vs = [(name, toSchema (Proxy :: Proxy a), toJSON v) | v <- vs]

    armIsDocumented (name, sch, v) = case v of
      Object o -> do
        let emitted = map Key.toText (KeyMap.keys o)
            label = name <> " (" <> maybe "?" show (KeyMap.lookup "tag" o) <> ")"
        assertEqual (label <> ": every emitted key is documented") [] (filter (`notElem` propKeys sch) emitted)
        assertBool
          (label <> ": the emitted tag is in the documented enum " <> show (tagEnum sch))
          (maybe False (`elem` tagEnum sch) (KeyMap.lookup "tag" o))
      _ -> assertFailure (name <> ": a tagged union must encode as an object, got " <> show v)
