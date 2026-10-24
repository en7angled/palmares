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

import Control.Exception (SomeException, toException)
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
import Data.List (isInfixOf, nub, sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Proxy (Proxy (..))
import Data.Swagger (Referenced (Inline), Schema, ToSchema, enum_, maxProperties, properties, toSchema)
import Data.Text (Text)
import GeniusYield.Providers.Common (SubmitTxException (..))
import GeniusYield.Transaction.Common (GYBuildTxError (..))
import GeniusYield.TxBuilder.Errors (GYTxMonadException (..))
import GeniusYield.Types (GYAssetClass, GYPubKeyHash, pubKeyHashToPlutus)
import Palmares.TxBuilding.Exceptions
  ( ApiFailure (..),
    TxBuildingException (ProfileNotFound, ProtocolPaused),
    classifyWriteFailure,
    traceCodesInRender,
  )
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
-- One definition, two users: 'constructorsOf' reads a type's constructor count off its own
-- 'GHC.Generics.Rep', and it is what makes the arm lists below exhaustive instead of merely claiming
-- to be. It lives in 'UnitTests.WritePath' because that module's whole subject is the same problem
-- one type over (the 26-constructor error table), and duplicating six lines of generic plumbing in
-- two test modules is the thing worth avoiding here.
import UnitTests.WritePath (constructorsOf)

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
-- arm costs one line here.
--
-- __"And nothing else notices it" used to end that sentence, and it was true.__ 'disputeArms' below
-- carried two of @DisputeActionType@'s three constructors — D-A added @ExpireDisputeAction@ and this
-- list did not grow — so "every arm encodes within its own published schema" was a claim about two
-- thirds of the type, and the one arm nobody had encoded was the one route with no coverage at all.
-- @adminActions@ was missing @SetDisputeTimeoutAction@ for the same reason, which is the third time
-- this repository has recorded that exact miss (see @PropertyTests.allAdminActions@).
--
-- Fixed by the case below, "every constructor of every action union is exercised": the counts come
-- from 'constructorsOf', which GHC derives, so a new constructor fails a test the day it is written
-- rather than the day somebody re-reads a comment.
profileArms :: [ProfileActionType]
profileArms =
  [ UpdateProfileAction (ac "00000000000000000000000000000000000000000000000000000000.6161") (Just "new") "ipfs://i",
    ClaimProfileAction PersonDRep pd,
    -- ADR 0003's two arms, and the two this list ALSO did not have — found by the coverage case
    -- below rather than by reading, which is the argument for the coverage case. @/claim-credential@
    -- and @/withdraw-credential@ are two of the nine service routes and neither of their request
    -- shapes had ever been encoded against its own published schema.
    --
    -- A real CIP-129 identifier rather than a placeholder: these arms are only encoded here, so the
    -- string is never parsed — but the document's example is what a client copies, and a value that
    -- would be refused by `parseClaimCredential` has no business standing in for one that would not.
    -- `Nothing` for the witness is the key-credential case, which is every claim until somebody
    -- claims a script.
    ClaimCredentialAction
      (ac "00000000000000000000000000000000000000000000000000000000.6a6a")
      "drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"
      Nothing
      pd,
    WithdrawCredentialAction
      (ac "00000000000000000000000000000000000000000000000000000000.6b6b")
      "drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"
      Nothing
      pd,
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
    ResolveDisputeAction (ac "00000000000000000000000000000000000000000000000000000000.6767") VerdictUpheld,
    -- D-A, and the arm this list was missing. It is the request body of @\/expire-dispute@ and the
    -- @\/build-tx@ arm that reaches 'Palmares.TxBuilding.Operations.expireDisputeTX', so without it
    -- neither the published schema nor the round trip below said anything about either.
    ExpireDisputeAction (ac "00000000000000000000000000000000000000000000000000000000.6868")
  ]

-- | The admin arm is deliberately absent: 'adminBodies' covers it, and it is the one arm that must
-- NOT parse back.
nonAdminActionArms :: [ActionType]
nonAdminActionArms = map ProfileAction profileArms <> map DisputeAction disputeArms

-- | Every arm of 'ActionType', including the two the HTTP surface treats specially.
--
-- Named rather than inlined into @armChecks@ so that the coverage case can count the DISTINCT tags
-- it emits: 'ActionType' has four constructors and this list has one value per inner action, so its
-- length is not the number of arms — the number of distinct @tag@s it encodes is.
actionArms :: [ActionType]
actionArms =
  nonAdminActionArms
    <> [ProtocolAction CleanupDustAction, AdminAction PauseProtocolAction Nothing]

-- | One per constructor, so the assertion is about the TYPE and not about the four arms that used
-- to parse. 'RotateArbiterAction' is here for the same reason: an admin action absent from this
-- list is an admin action nobody has checked is refused over HTTP.
--
-- 'SetDisputeTimeoutAction' was that action. It is the one admin power with a direct bearing on a
-- user's money — @opDisputeTimeoutMs@ is how long a deposit can sit undecided — and nothing had
-- checked that a request body carrying it is refused.
adminActions :: [AdminActionType]
adminActions =
  [ PauseProtocolAction,
    UnpauseProtocolAction,
    SetFeesAction Nothing,
    SetMinUTxOValueAction 1_000_000,
    RotateAdminAction (PubKeyCredential (pubKeyHashToPlutus pkhA)) Nothing,
    SetDisputeDepositAction 5_000_000,
    RotateArbiterAction (PubKeyCredential (pubKeyHashToPlutus pkhA)) Nothing,
    SetDisputeTimeoutAction 2_592_000_000
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
    [ writeFailureTests, ---- the published schema is the wire format ------------------------------------------------
      testCase "ProfileActionType publishes a TAGGED object, not a constructor-keyed one" $ do
        let s = toSchema (Proxy @ProfileActionType)
        assertBool "tag is a property" ("tag" `elem` propKeys s)
        -- `maxProperties: 1` is the fingerprint of swagger2's constructor-keyed sum encoding, and
        -- the constructor names as PROPERTY keys are the other half of it.
        assertEqual "no maxProperties" Nothing (s ^. maxProperties)
        assertEqual
          "no property is named after a constructor"
          []
          ( filter
              (`elem` propKeys s)
              [ "UpdateProfileAction",
                "ClaimProfileAction",
                -- The two ADR 0003 arms, absent from this list for the same reason they were absent
                -- from 'profileArms': nobody had enumerated the type since they landed.
                "ClaimCredentialAction",
                "WithdrawCredentialAction",
                "IssueAttestationAction",
                "AcceptAttestationAction"
              ]
          ),
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
      -- The guard on the lists above, and the only thing that makes "one value per constructor"
      -- true rather than aspirational. 'constructorsOf' is derived from each type's own 'Rep', so a
      -- new arm moves the expected number without anybody editing this case.
      --
      -- 'ActionType' is counted by DISTINCT TAGS and not by length, because 'actionArms' holds one
      -- value per inner action rather than one per arm of the union.
      testCase "every constructor of every action union is exercised" $ do
        assertEqual "ProfileActionType arms" (constructorsOf @ProfileActionType) (length profileArms)
        assertEqual "DisputeActionType arms" (constructorsOf @DisputeActionType) (length disputeArms)
        assertEqual "AdminActionType arms" (constructorsOf @AdminActionType) (length adminActions)
        assertEqual
          "ActionType arms"
          (constructorsOf @ActionType)
          (length (nub (mapMaybe (field "tag" . toJSON) actionArms))),
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
      --
      -- `oracle` is the registry's OWN parameters — the deposit, the dispute timeout, the minimum
      -- UTxO, both fees and the admin and arbiter credentials. It is asserted here as part of the
      -- whole key set rather than by name because this service is the ONLY one that can publish
      -- them: query-api carries no Cardano provider and its db-sync is indexed without UTxOs, so
      -- losing this field would make three screens unbuildable with nowhere else to look. It is a
      -- different fact from `oracle_paused`, which stays a separate read off the gate every write
      -- goes through, precisely so it cannot disagree with the production check.
      testCase "/status reports the provider, the deployed scripts and the oracle's paused flag" $ do
        doc <- readSwagger
        sort (objKeys (fromMaybe Null (path ["definitions", "InteractionStatusResponse", "properties"] doc)))
          @?= ["deployed_scripts", "network", "oracle", "oracle_paused", "provider", "version"],
      testCase "the Swagger title and version name this product" $ do
        doc <- readSwagger
        (path ["info", "title"] doc, path ["info", "version"] doc)
          @?= (Just (String "Palmares Interaction API"), Just (String "3.5.0")),
      -- The statuses the service can return, as the document declares them. Asserted as the WHOLE
      -- declared set on one operation rather than with `has`, because the defect was an OMISSION:
      -- `index(…) != null` on five keys would have passed on a document that declared four of them
      -- and dropped the fifth. 405/406/415 come from the router (see `jsonRoutingRefusals`), 500 and
      -- 502 from a handler, and every one of them was reachable before it was published.
      testCase "every status the service can return is declared on every operation" $ do
        doc <- readSwagger
        let declaredOn p = sort (objKeys (fromMaybe Null (path ["paths", p, "post", "responses"] doc)))
        declaredOn "/expire-dispute" @?= ["200", "400", "404", "405", "406", "415", "500", "502", "503"],
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
        <> checksFor "ActionType" actionArms

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

-------------------------------------------------------------------------------

-- * The write path's error table — OF-05

-------------------------------------------------------------------------------

-- | What a client is told when a write fails.
--
-- __Why a test exists at all.__ The translation used to be a @case@ inside the handler, typed by its
-- own patterns, so there was nothing to call without an HTTP server and nothing was called. It
-- collapsed four distinct failures into "Not enough ADA in your wallet" and let a fifth escape to
-- Warp's text/plain 500 with no @code@ (@OF-05@). It is one pure function now, and this is the
-- table.
--
-- The script arm is the one the finding is about: a validator refusing a transaction told the user
-- to add funds. The codes come out of the rendered Plutus failure, which is the same place
-- @Test.Helpers.failedWithTrace@ has read them since the first negative test — one parser, with the
-- emulator suite as its gate.
writeFailureTests :: TestTree
writeFailureTests =
  testGroup
    "write failures carry a code a client can act on (OF-05)"
    [ testCase "our own exception keeps its own code and status" $ do
        let f = classifyWriteFailure (toException (GYApplicationException ProfileNotFound))
        (afStatus f, afCode f) @?= (404, "ProfileNotFound"),
      testCase "a paused protocol is a 503, not a 400" $ do
        let f = classifyWriteFailure (toException (GYApplicationException ProtocolPaused))
        (afStatus f, afCode f) @?= (503, "ProtocolPaused"),
      testCase "a VALIDATOR refusal is ScriptRefused and names the trace codes, not InsufficientFunds" $ do
        -- The render fragment is the shape cardano-api actually produces, taken from an emulator
        -- failure: `dpfExecutionLogs = ["D6","PT5"]`.
        let f = classifyWriteFailure scriptFailure
        afStatus f @?= 400
        afCode f @?= "ScriptRefused"
        assertBool ("the message must name the codes: " <> afMessage f) ("D6" `isInfixOf` afMessage f)
        assertBool ("and all of them: " <> afMessage f) ("PT5" `isInfixOf` afMessage f),
      testCase "a balancing shortfall is still InsufficientFunds" $ do
        let f = classifyWriteFailure (toException (GYBuildTxException GYBuildTxNoSuitableCollateral))
        (afStatus f, afCode f) @?= (400, "InsufficientFunds"),
      testCase "the ExUnits and size ceilings are NOT shortfalls — adding ADA does nothing about them" $ do
        let tooBig = classifyWriteFailure (toException (GYBuildTxException (GYBuildTxExUnitsTooBig (10, 10) (20, 20))))
            tooLarge = classifyWriteFailure (toException (GYBuildTxException (GYBuildTxSizeTooBig 16384 20000)))
        (afCode tooBig, afCode tooLarge) @?= ("TxTooExpensive", "TxTooLarge")
        (afStatus tooBig, afStatus tooLarge) @?= (400, 400),
      testCase "a submission the provider rejected is a 502, not a 500 with no code" $ do
        let f = classifyWriteFailure (toException (SubmitTxException "the node rejected the transaction"))
        (afStatus f, afCode f) @?= (502, "ProviderError"),
      testCase "anything unrecognised is still a 500, but with a code in the body" $ do
        let f = classifyWriteFailure (toException (userError "something nobody classified"))
        (afStatus f, afCode f) @?= (500, "InternalError"),
      ---- the parser the script arm depends on ----------------------------------------------------
      testCase "the trace-code parser reads every code, in order" $
        traceCodesInRender renderedLogs @?= ["D6", "PT5"],
      testCase "no marker means no codes — a render change degrades, it does not invent" $ do
        traceCodesInRender "GYBuildTxException (GYBuildTxBalancingError ...)" @?= []
        traceCodesInRender "" @?= [],
      testCase "an empty log list is no codes, not one empty code" $
        traceCodesInRender "dpfExecutionLogs = []}" @?= []
    ]
  where
    renderedLogs = "DebugPlutusFailure {dpfExecutionUnits = ..., dpfExecutionLogs = [\"D6\",\"PT5\"]}"
    scriptFailure :: SomeException
    scriptFailure = toException (userError ("TxBodyScriptExecutionError " <> renderedLogs))
