{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The dispute protocol: its pure rules, and then a real deposit through a real ledger.
--
-- The first group is a function of the on-chain types alone, so it needs no provider. The second is
-- T-ATTEST-5's emulator half, unblocked by the off-chain write path, and it is where the deposit
-- actually moves.
--
-- Two of the pure tests are about things the chain deliberately does NOT enforce, and they are here
-- so that the boundary is written down rather than assumed:
--
--   * 'checkNoOpenDispute' is an off-chain courtesy. There is no trace code for it, because there is
--     no on-chain check: "one open dispute at a time" would need an index UTxO every dispute had to
--     contend for. What bounds spam is the deposit — N disputes cost N deposits.
--   * the deposit comes back on BOTH verdicts, so losing a dispute costs only network fees. There is
--     no punitive verdict, and that is why 'Verdict' has exactly two constructors.
--
-- __@D1@ and @D3@ need a malicious builder.__ 'Palmares.TxBuilding.Operations.resolveDisputeTX'
-- demands the datum's admin as a required signer, so a non-admin produces a transaction nobody can
-- sign and the submission dies before any script runs; and it throws @DisputeAlreadyResolved@ off
-- chain, so a second resolution never reaches the validator either. Both would pass as a bare
-- @mustFail@ with the on-chain guard deleted — the mistake 'UnitTests.Oracle' documents for @O1@.
module UnitTests.Dispute (tests, disputeEmulatorTests) where

import Control.Monad (void)
import Data.Text (Text)
import Data.Text qualified as T
import GeniusYield.Test.Clb
import GeniusYield.Test.FakeCoin (FakeCoin (..))
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder
import GeniusYield.TxBuilder.User qualified as User
import GeniusYield.Types
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types qualified as Domain
import Palmares.Onchain.CIP68 (extra)
import Palmares.Onchain.Protocol.Lookup (checkFee, feeFor)
import Palmares.Onchain.Protocol.Types
  ( FeeConfig (..),
    MintAction (..),
    OnchainDispute (..),
    OracleParams (..),
    Verdict (..),
    attestationIsAccepted,
    checkNoOpenDispute,
    resolveDispute,
  )
import Palmares.Onchain.Utils (nameFromTxOutRef)
import Palmares.TxBuilding.Context (DeployedScriptsContext)
import Palmares.TxBuilding.Lookups (getAttestationDatumAndValue, getDisputeDatumAndValue)
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import PlutusLedgerApi.V3
  ( Address (..),
    Credential (PubKeyCredential),
    POSIXTime (..),
    PubKeyHash (..),
    TxId (..),
    TxOutRef (..),
  )
import PlutusTx (Data (..), builtinDataToData, toBuiltinData)
import Test.Fixtures (disputeStatementData, drepProfileData, milestoneAttestationData, orgProfileData)
import Test.Helpers (assert, failedWithTrace)
import Test.Tasty
-- `assert` is exported by BOTH Test.Helpers and Test.Tasty.HUnit, and this module is the only one
-- that needs both: the pure group below asserts with `@?=` in IO, the emulator group asserts inside
-- `GYTxMonadClb`, where HUnit's IO-based `assert` would not typecheck anyway. Hiding the one that
-- cannot be meant here is cheaper than qualifying eleven call sites.
import Test.Tasty.HUnit hiding (assert)
import TestRuns
  ( deployValidators,
    disputeInteraction,
    maliciousResolveDispute,
    maliciousResolveTwoDisputes,
    profileInteraction,
  )

tests :: TestTree
tests =
  testGroup
    "disputes"
    [ -- A dispute's token name comes from the seed TxOutRef it spends, which is what makes two
      -- disputes against the same attestation distinct UTxOs rather than a collision. Same primitive
      -- the minting policy uses, so this is the real derivation and not a restatement of it.
      testCase "a dispute's name is derived from its seed, so two disputes never collide" $
        (nameFromTxOutRef seedA /= nameFromTxOutRef seedB) @?= True,
      testCase "the same seed always derives the same name" $
        nameFromTxOutRef seedA @?= nameFromTxOutRef seedA,
      testCase "an unresolved dispute carries no verdict" $
        disputeVerdict (freshDispute targetA openerA) @?= Nothing,
      -- Whole-record equality, not a field read: the validator computes the expected output datum
      -- with this function and compares the WHOLE datum, so anything resolveDispute preserves is a
      -- field the resolution provably cannot touch. A field read would pass even if resolving also
      -- quietly rewrote the target.
      testCase "resolving writes the verdict and changes nothing else" $
        resolveDispute VerdictUpheld (freshDispute targetA openerA)
          @?= (freshDispute targetA openerA) {disputeVerdict = Just VerdictUpheld},
      testCase "Verdict is two constructors at indices 0 and 1" $
        map constructorIndexOf [VerdictUpheld, VerdictRejected] @?= [0, 1],
      -- THE DEPOSIT COMES BACK EITHER WAY. The pure half of it: resolution cannot change the amount
      -- recorded at open time or the address it returns to, under either verdict. The validator's D4
      -- then pays exactly that recorded amount to exactly that address, which is why losing a
      -- dispute costs only network fees — and why there is no third, punitive verdict.
      testCase "neither verdict can change the recorded deposit or its destination" $
        map
          (\v -> let d = resolveDispute v (freshDispute targetA openerA) in (disputeDeposit d, disputeDepositTo d))
          [VerdictUpheld, VerdictRejected]
          @?= replicate 2 (disputeDeposit (freshDispute targetA openerA), depositAddr),
      -- ---- checkNoOpenDispute: off-chain courtesy, not a protocol rule ------------------------
      testCase "a second dispute against the same attestation is refused while one is open" $
        checkNoOpenDispute targetA [freshDispute targetA openerB] @?= False,
      testCase "a second dispute is allowed once the first is resolved" $
        checkNoOpenDispute targetA [resolveDispute VerdictRejected (freshDispute targetA openerB)] @?= True,
      -- Target-scoped, which is the half that would be silently wrong if the predicate ignored the
      -- target: every attestation would look contested as soon as any dispute was open anywhere.
      testCase "an open dispute against a DIFFERENT attestation does not block this one" $
        checkNoOpenDispute targetA [freshDispute targetB openerB] @?= True,
      testCase "no disputes at all is not an open dispute" $
        checkNoOpenDispute targetA [] @?= True,
      -- ---- fees -------------------------------------------------------------------------------
      testCase "MintActionDispute is at constructor index 2" $
        constructorIndexOf MintActionDispute @?= 2,
      -- Opening a dispute carries no protocol fee, whatever the oracle has priced the others at.
      -- Contesting a false claim must not cost money that never comes back.
      testCase "a dispute carries no protocol fee, for any fee configuration" $
        feeFor MintActionDispute feeCfg @?= 0,
      -- The reason `checkFee` needed a zero-fee short circuit. Without it the check demands an
      -- output to the fee address carrying at least ZERO lovelace, which no honest transaction
      -- builds — so a dispute would have been unmintable the moment fees were configured at all,
      -- and `OracleSetFees` with any zero field would have bricked that action. This is the case
      -- that fails on the old code.
      testCase "a zero fee requires no fee output at all" $
        checkFee oracleWithFees MintActionDispute [] @?= True,
      testCase "a priced action still requires its fee output" $
        checkFee oracleWithFees MintActionAttestation [] @?= False,
      testCase "no fee configuration means no fee for any action" $
        map (\a -> checkFee oracleNoFees a []) [MintActionProfile, MintActionAttestation, MintActionDispute]
          @?= [True, True, True]
    ]
  where
    cs = CurrencySymbol "\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10"
    acOf name = AssetClass (cs, TokenName name)

    targetA = acOf "\0\6C\176target-a"
    targetB = acOf "\0\6C\176target-b"
    openerA = acOf "\0\6C\176opener-a"
    openerB = acOf "\0\6C\176opener-b"

    pkh = PubKeyHash "\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3"
    depositAddr = Address (PubKeyCredential pkh) Nothing

    seedA = TxOutRef (TxId "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1") 0
    seedB = TxOutRef (TxId "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1") 1

    freshDispute target opener =
      OnchainDispute
        { disputeId = acOf "\0\6C\176dispute",
          disputeTarget = target,
          disputeOpenedBy = opener,
          disputeOpenedAt = POSIXTime 1_700_000_000_000,
          disputeDeposit = 5_000_000,
          disputeDepositTo = depositAddr,
          disputeOracleToken = acOf "oracle",
          disputeStaleAfter = POSIXTime (1_700_000_000_000 + 2_592_000_000),
          disputeVerdict = Nothing
        }

    feeCfg =
      FeeConfig
        { fcFeeAddress = depositAddr,
          fcProfileCreationFee = 2_000_000,
          fcAttestationFee = 1_000_000
        }

    oracleWithFees = baseOracle {opFeeConfig = Just feeCfg}
    oracleNoFees = baseOracle

    baseOracle =
      OracleParams
        { opAdminPkh = pkh,
          opPaused = False,
          opFeeConfig = Nothing,
          opMinUTxOValue = 2_000_000,
          opDisputeDeposit = 5_000_000,
          opDisputeTimeoutMs = 2_592_000_000
        }

    -- Read the constructor index straight out of the encoding, which is what a deployed validator
    -- sees — rather than trusting the makeIsDataSchemaIndexed call to say what it means.
    constructorIndexOf x = case builtinDataToData (toBuiltinData x) of
      Constr i _ -> i
      _ -> -1

------------------------------------------------------------------------------------------------

-- * The emulator half: a real deposit, in a real ledger

------------------------------------------------------------------------------------------------

-- | The deposit is the only thing bounding dispute spam and the only value this protocol ever holds
-- on a user's behalf, so what these cases assert is where the lovelace actually is: locked in the
-- dispute's own UTxO while it is open, and back in the disputer's wallet once a verdict is written —
-- on __either__ verdict, which is why there is no punitive third.
disputeEmulatorTests :: (HasCallStack) => TestTree
disputeEmulatorTests =
  testGroup
    "Dispute Lifecycle Tests"
    [ mkTestFor "Test Case 6.1: open a dispute against an accepted attestation, deposit locked" openLocksDeposit,
      mkTestFor "Test Case 6.2: the oracle admin resolves it upheld, deposit returned" (resolveReturnsDeposit Domain.VerdictUpheld VerdictUpheld),
      mkTestFor "Test Case 6.3: the oracle admin resolves it rejected, deposit returned" (resolveReturnsDeposit Domain.VerdictRejected VerdictRejected),
      mkTestFor "Test Case 6.4: a non-admin resolution FAILS (D1)" nonAdminResolutionFails,
      mkTestFor "Test Case 6.5: resolving an already-resolved dispute FAILS (D3)" doubleResolutionFails,
      mkTestFor "Test Case 6.6: the attestation is untouched by the dispute's whole lifecycle" attestationUntouched,
      mkTestFor "Test Case 6.7: a second dispute while one is open is refused off-chain" secondDisputeRefused,
      mkTestFor "Test Case 6.8: a payout address this tx does not spend from FAILS (Md8)" foreignDepositToFails,
      mkTestFor "Test Case 6.9: an opener id under a FOREIGN policy FAILS (Md4)" foreignOpenerFails,
      mkTestFor "Test Case 6.10: two disputes resolved with ONE returned deposit FAILS (D6)" twoDisputesOneDepositFails
    ]
  where
    -- Test Case 6.1. The deposit is part of the LOCKED value, not a payment to anyone, which is the
    -- whole economic mechanism: it sits in the dispute's UTxO until a verdict releases it.
    openLocksDeposit :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    openLocksDeposit info@TestInfo {..} = do
      (ctx, _issuerAC, disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      (_txId, disputeAC) <- open ctx (w2 testWallets) attestationAC disputerAC
      waitNSlots_ 1

      (datum, plutusValue) <- getDisputeDatumAndValue disputeAC
      let dispute = extra datum
      assert (disputeTarget dispute == assetClassToPlutus attestationAC)
      assert (disputeOpenedBy dispute == assetClassToPlutus disputerAC)
      assert (disputeVerdict dispute == Nothing)
      -- The amount is read from the oracle at open time and then RECORDED here; resolution reads the
      -- record and never the oracle, so a later reprice cannot touch this dispute.
      assert (disputeDeposit dispute == 5_000_000)

      gyValue <- valueFromPlutus' plutusValue
      -- min-UTxO (1 ADA) plus the deposit (5 ADA). An assertion on the datum alone would pass even
      -- if the lovelace never arrived. @>=@ rather than @==@ for the reason the validators use it:
      -- the balancer may top an output up to the ledger's min-ADA.
      assert (valueAda gyValue >= 6_000_000)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A dispute was opened and its deposit is locked."

    -- Test Cases 6.2 and 6.3, one body: the deposit comes back on EITHER verdict, so the only thing
    -- that differs is which constructor lands in the datum. Writing them as two bodies would invite
    -- the two to drift, and the point is precisely that they do not.
    resolveReturnsDeposit :: (HasCallStack) => Domain.DisputeVerdict -> Verdict -> TestInfo -> GYTxMonadClb ()
    resolveReturnsDeposit domainVerdict onchainVerdict info@TestInfo {..} = do
      (ctx, _issuerAC, disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      (_txId, disputeAC) <- open ctx (w2 testWallets) attestationAC disputerAC
      waitNSlots_ 1

      -- w2 opened and pays no fee on the resolution, so its balance moves by exactly the deposit.
      (_, delta) <- withBalance "disputeDepositReturn" (w2 testWallets) $ do
        void $ disputeInteraction ctx (w1 testWallets) (ResolveDisputeAction disputeAC domainVerdict)
        waitNSlots_ 1
      assert (valueAda delta == 5_000_000)

      (datum, plutusValue) <- getDisputeDatumAndValue disputeAC
      assert (disputeVerdict (extra datum) == Just onchainVerdict)
      -- And the deposit LEFT the dispute's UTxO rather than being duplicated out of the admin's
      -- pocket: what remains cannot still contain it. Deliberately an inequality and not
      -- @== opMinUTxOValue@ — the balancer tops an output up to the ledger's min-ADA, which for a
      -- CIP-68 datum is above the oracle's 1 ADA, and which is exactly why every validator's value
      -- check is @>=@ rather than @==@.
      gyValue <- valueFromPlutus' plutusValue
      assert (valueAda gyValue < 5_000_000)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ "Resolved " <> show onchainVerdict <> "; the deposit came back."

    -- Test Case 6.4. If @D1@ did not hold, anyone could write a verdict on anyone's dispute and take
    -- the deposit wherever the datum points — which is to say the oracle admin would not be the
    -- arbiter at all.
    nonAdminResolutionFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    nonAdminResolutionFails info@TestInfo {..} = do
      (ctx, _issuerAC, disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      (_txId, disputeAC) <- open ctx (w2 testWallets) attestationAC disputerAC
      waitNSlots_ 1

      mustFailWith (failedWithTrace "D1") $
        void $
          maliciousResolveDispute ctx (w3 testWallets) disputeAC Domain.VerdictUpheld

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A non-admin resolution was rejected by the validator (D1)."

    -- Test Case 6.5. A verdict is written ONCE: without @D3@ the admin could rewrite an upheld
    -- dispute as rejected, or an attacker who later obtained the key could rewrite history that was
    -- already settled. The admin signs here, so @D1@ passes and @D3@ is what refuses.
    doubleResolutionFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    doubleResolutionFails info@TestInfo {..} = do
      (ctx, _issuerAC, disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      (_txId, disputeAC) <- open ctx (w2 testWallets) attestationAC disputerAC
      waitNSlots_ 1
      void $ disputeInteraction ctx (w1 testWallets) (ResolveDisputeAction disputeAC Domain.VerdictUpheld)
      waitNSlots_ 1

      mustFailWith (failedWithTrace "D3") $
        void $
          maliciousResolveDispute ctx (w1 testWallets) disputeAC Domain.VerdictRejected

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A second verdict was rejected by the validator (D3)."

    -- Test Case 6.6, and it is the spec's §4.3 property rather than a smoke test: the attestation is
    -- shown beside its dispute and is never hidden, altered or deleted. Nothing in the dispute path
    -- spends it, re-datums it or even reads it as an input — only its asset class is checked for the
    -- protocol's currency symbol — which is also what keeps the attestation path's ExUnits unchanged.
    -- Byte equality of datum AND value, across open and resolve.
    attestationUntouched :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    attestationUntouched info@TestInfo {..} = do
      (ctx, _issuerAC, disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      before <- getAttestationDatumAndValue attestationAC

      (_txId, disputeAC) <- open ctx (w2 testWallets) attestationAC disputerAC
      waitNSlots_ 1
      afterOpen <- getAttestationDatumAndValue attestationAC
      assert (afterOpen == before)

      void $ disputeInteraction ctx (w1 testWallets) (ResolveDisputeAction disputeAC Domain.VerdictUpheld)
      waitNSlots_ 1
      afterResolve <- getAttestationDatumAndValue attestationAC
      assert (afterResolve == before)
      -- Still accepted. A dispute does not un-accept anything; it is a second record pointing at the
      -- first, and what a reader does with the pair is the read layer's business.
      assert (attestationIsAccepted (extra (fst afterResolve)))

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "The attestation survived the dispute lifecycle byte-identical."

    -- Test Case 6.7, the emulator half of a refusal whose message 'UnitTests.WritePath' pins. Plain
    -- 'mustFail' and NO trace code, deliberately: @DisputeAlreadyOpen@ is thrown by
    -- `openDisputeTX` before anything is built, and there is no on-chain check to name. The validator
    -- really does permit a second dispute — what bounds the spam is that N disputes cost N deposits —
    -- so this is a courtesy to a human who did not mean it, and the test must not claim more.
    secondDisputeRefused :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    secondDisputeRefused info@TestInfo {..} = do
      (ctx, _issuerAC, disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      _ <- open ctx (w2 testWallets) attestationAC disputerAC
      waitNSlots_ 1

      mustFail $ void $ open ctx (w2 testWallets) attestationAC disputerAC

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A second open dispute was refused off-chain (DisputeAlreadyOpen)."

    -- Test Case 6.8. `Md8`. The payout address went into the permanent datum unchecked, and
    -- resolution pays it with `txOutAddress == disputeDepositTo`. An address no real output can
    -- carry — `PubKeyCredential (PubKeyHash "")` is representable in Plutus data and not in a ledger
    -- address — makes `D4` UNSATISFIABLE, so the oracle admin cannot resolve the dispute ever. Both
    -- the deposit and the dispute's NFT stay locked and the dispute stays open against its target
    -- forever. That is the attack: five ADA buys a permanent unresolvable accusation on somebody
    -- else's record, and `od_deposit_to` is a field of the public API.
    --
    -- The address used here is w3's, which is a perfectly real address — the point is that this
    -- transaction does not spend from it. A validator cannot tell "real but not mine" from
    -- "impossible"; what it can check is that the transaction just demonstrated control of it, which
    -- rules out both.
    --
    -- `Palmares.DomainTypes.Core.Actions.od_deposit_to`'s own Haddock said "pointing it somewhere
    -- useless costs only the disputer". It does not: it costs the subject of the attestation.
    foreignDepositToFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    foreignDepositToFails info@TestInfo {..} = do
      (ctx, _issuerAC, disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      let strangerAddr = User.userChangeAddress (w3 testWallets)
      mustFailWith (failedWithTrace "Md8") $
        void $
          openWith ctx (w2 testWallets) attestationAC disputerAC (Just strangerAddr)
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A payout address the tx does not spend from was rejected (Md8)."

    -- Test Case 6.9. `Md4`, which used to check only the TARGET's currency symbol while the sibling
    -- mint path's `Mg` has always checked both of its profile ids.
    --
    -- `Md3` is what authorises the opener: the transaction must spend the user NFT derived from
    -- `openedBy`. `spendUserNFTForProfile` is policy-agnostic and `deriveUserFromRefAC` only swaps
    -- the CIP-67 prefix, keeping the currency symbol — so a token minted under the CALLER's own
    -- policy satisfies it, and the authorisation is self-issued. Before this, anyone could open a
    -- dispute while owning no profile in this protocol, and the dispute recorded an opener id that
    -- does not exist.
    --
    -- The foreign NFT is minted first, under atlas's fake-coin policy, with the CIP-67 USER prefix
    -- on its name. The claimed opener id is the same policy with the REF prefix, so the derivation
    -- lands exactly on the token w3 holds. Note that w3 has no profile at all here, which is the
    -- whole point.
    foreignOpenerFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    foreignOpenerFails info@TestInfo {..} = do
      (ctx, _issuerAC, _disputerAC, attestationAC) <- deployWithAcceptedAttestation info
      asUser (w3 testWallets) $ mintTestAssets [(foreignUserCoin, 1)]
      waitNSlots_ 1
      mustFailWith (failedWithTrace "Md4") $
        void $
          openWith ctx (w3 testWallets) attestationAC foreignOpenerAC Nothing
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "An opener id under a foreign policy was rejected (Md4)."

    -- Test Case 6.10. `D6`, and this is the exploit rather than a shape: two deposits leave the
    -- script, one comes back, and the difference lands in the change of whoever built the
    -- transaction. `D1` means that is the oracle admin.
    --
    -- The precondition is ordinary, not contrived: both disputes are opened by w2 with no
    -- `od_deposit_to`, so both default to w2's change address and both `paysDeposit` predicates
    -- accept the same output. One person contesting two attestations is the normal case.
    --
    -- Two attestations are needed because a second dispute against the SAME attestation is refused
    -- off-chain (6.7), so the second one is issued here.
    twoDisputesOneDepositFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    twoDisputesOneDepositFails info@TestInfo {..} = do
      (ctx, issuerAC, disputerAC, attestationA) <- deployWithAcceptedAttestation info
      attestationB <- issueAndAccept ctx (w1 testWallets) (w2 testWallets) issuerAC disputerAC
      waitNSlots_ 1

      (_t1, disputeA) <- open ctx (w2 testWallets) attestationA disputerAC
      waitNSlots_ 1
      (_t2, disputeB) <- open ctx (w2 testWallets) attestationB disputerAC
      waitNSlots_ 1

      mustFailWith (failedWithTrace "D6") $
        void $
          maliciousResolveTwoDisputes ctx (w1 testWallets) disputeA disputeB Domain.VerdictUpheld
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Resolving two disputes with one returned deposit was rejected (D6)."

    -- CIP-67 prefixes, as hex, because the whole trick is which four bytes a token name starts with:
    -- `000de140` is the user half and `000643b0` the reference half. The fake-coin policy is derived
    -- from the token NAME, so the policy that mints the user token is also the policy the claimed
    -- reference id must name — which is why one coin gives both halves of this attack.
    foreignUserCoin :: FakeCoin
    foreignUserCoin = FakeCoin (unsafeTokenName "000de140666f726569676e")

    foreignOpenerAC :: GYAssetClass
    foreignOpenerAC = case fakeCoin foreignUserCoin of
      GYToken pid _ -> GYToken pid (unsafeTokenName "000643b0666f726569676e")
      ac -> error ("foreignOpenerAC: fake coin is not a token: " <> show ac)

    unsafeTokenName :: Text -> GYTokenName
    unsafeTokenName hex =
      either (\e -> error ("unsafeTokenName: " <> T.unpack hex <> ": " <> T.unpack e)) id (tokenNameFromHex hex)

    -- Issue one more attestation about the same subject and have the subject accept it, so there are
    -- two accepted attestations to dispute. Returns the new attestation's id.
    issueAndAccept ::
      (HasCallStack) =>
      DeployedScriptsContext ->
      User ->
      User ->
      GYAssetClass ->
      GYAssetClass ->
      GYTxMonadClb GYAssetClass
    issueAndAccept ctx issuer subject issuerAC subjectAC = do
      (_t, attestationAC) <-
        profileInteraction
          ctx
          issuer
          ( IssueAttestationAction
              { aa_subject_profile_id = subjectAC,
                aa_issuer_profile_id = issuerAC,
                aa_kind = Domain.MilestoneDelivered,
                aa_profile_data = milestoneAttestationData,
                aa_other_metadata = [],
                aa_claimed_period = Nothing
              }
          )
          Nothing
      waitNSlots_ 1
      void $ profileInteraction ctx subject (AcceptAttestationAction attestationAC) Nothing
      waitNSlots_ 1
      return attestationAC

    -- Deploy, give w1 an organisation and w2 a DRep person, issue an attestation about w2 and have
    -- w2 accept it. Every case disputes an ACCEPTED attestation, because that is the interesting
    -- one: a pending claim nobody has agreed to needs no contesting.
    deployWithAcceptedAttestation ::
      (HasCallStack) =>
      TestInfo ->
      GYTxMonadClb (DeployedScriptsContext, GYAssetClass, GYAssetClass, GYAssetClass)
    deployWithAcceptedAttestation TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000
      (_t1, issuerAC) <-
        profileInteraction ctx (w1 testWallets) (ClaimProfileAction Domain.Organization Nothing Nothing orgProfileData) Nothing
      waitNSlots_ 1
      (_t2, subjectAC) <-
        profileInteraction ctx (w2 testWallets) (ClaimProfileAction Domain.PersonDRep Nothing Nothing drepProfileData) Nothing
      waitNSlots_ 1
      (_t3, attestationAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = subjectAC,
                aa_issuer_profile_id = issuerAC,
                aa_kind = Domain.MilestoneDelivered,
                aa_profile_data = milestoneAttestationData,
                aa_other_metadata = [],
                aa_claimed_period = Nothing
              }
          )
          Nothing
      waitNSlots_ 1
      void $ profileInteraction ctx (w2 testWallets) (AcceptAttestationAction attestationAC) Nothing
      waitNSlots_ 1
      return (ctx, issuerAC, subjectAC, attestationAC)

    -- The disputer is the attestation's own subject here, which is the ordinary case: the party a
    -- false claim is about is the one who wants it contested. Any profile holder could do it.
    open ::
      (HasCallStack) =>
      DeployedScriptsContext ->
      User ->
      GYAssetClass ->
      GYAssetClass ->
      GYTxMonadClb (GYTxId, GYAssetClass)
    -- Nothing for the payout: the deposit returns to the opener's change address, which is the only
    -- sensible default a validator cannot work out for itself.
    open ctx wallet attestationAC disputerAC = openWith ctx wallet attestationAC disputerAC Nothing

    -- The same thing with both of @handleOpenDispute@'s unchecked parameters free, because both were
    -- reachable through the ordinary off-chain path: 'openDisputeTX' takes the opener's profile id
    -- and the payout address from the caller and constrains neither. See 6.8 and 6.9.
    --
    -- @od_deposit_to@ is deliberately not constrained off chain either. @Md8@'s rule is "an address
    -- this transaction spends from", which legitimately includes one outside the disputer's
    -- 'UserAddresses' — a cold wallet they also spend from here. A guard requiring it to be one of
    -- @ownAddrs@ would be stricter than the validator and would refuse that.
    openWith ::
      (HasCallStack) =>
      DeployedScriptsContext ->
      User ->
      GYAssetClass ->
      GYAssetClass ->
      Maybe GYAddress ->
      GYTxMonadClb (GYTxId, GYAssetClass)
    openWith ctx wallet attestationAC openerAC mDepositTo =
      disputeInteraction
        ctx
        wallet
        ( OpenDisputeAction
            { od_attestation_id = attestationAC,
              od_opened_by_profile_id = openerAC,
              od_deposit_to = mDepositTo,
              od_profile_data = disputeStatementData
            }
        )
