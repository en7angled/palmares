{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The oracle, in a real ledger.
--
-- Everything the protocol can be re-tuned without a redeployment lives in one UTxO's datum, guarded
-- by one signature. So the two questions worth a transaction are: does each admin action land the
-- change it claims, and is the signature check load-bearing.
--
-- __Why the admin check needs a malicious builder.__ The obvious negative — run an admin action as a
-- wallet that is not the admin — never reaches the validator. 'Palmares.TxBuilding.Operations.updateOracleTX'
-- reads the current admin out of the datum and adds @mustBeSignedBy adminPkh@, so a non-admin builds
-- a transaction it cannot sign and the submission dies at the required-signer layer with no script
-- run at all. The inherited suite's "non-admin oracle update fails" test passed for exactly that
-- reason and would have kept passing with @O1@ deleted. 'TestRuns.maliciousOracleUpdate' is the same
-- transaction signed by the attacker instead, and it is what the @O1@ cases below use.
--
-- __What @(O1)@ in a test name does and does not claim.__ It names the check the case is aimed at,
-- not a string anyone asserted. The default build compiles the validators with
-- @PlutusTx.Plugin:remove-trace@, so no trace code reaches any log — the failure reads "an error has
-- occurred" and @mustFail@ cannot distinguish one rejected transaction from another. What these
-- cases do establish is that the transaction reaches the validator and the validator refuses it,
-- which is the part the required-signer failure never showed. To see the code itself, build with
-- @-f preserve-logging@ (see the flag in @palmares.cabal@).
module UnitTests.Oracle
  ( oracleTests,
  )
where

import Control.Monad (void)
import Control.Monad.Reader (runReaderT)
import GHC.Stack
import GeniusYield.Test.Clb
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder
import GeniusYield.TxBuilder.User qualified as User
import GeniusYield.Types
import Palmares.DomainTypes.Core.Actions
import Palmares.Onchain.Protocol.Types (FeeConfig (..), OracleParams (..))
import Palmares.TxBuilding.Lookups (queryOracleParams)
import PlutusTx.Prelude (isNothing)
import Test.Helpers (assert, queryOracle)
import Test.Tasty
import TestRuns
  ( adminInteraction,
    deployValidators,
    maliciousMintOracleNFTWithExtraToken,
    maliciousMintOracleNFTWrongName,
    maliciousOracleUpdate,
    userPlutusPkh,
  )

oracleTests :: (HasCallStack) => TestTree
oracleTests =
  testGroup
    "Oracle"
    [ oracleDeploymentTests,
      oracleAdminTests,
      oracleRotationTests,
      oracleNFTTests
    ]

oracleDeploymentTests :: (HasCallStack) => TestTree
oracleDeploymentTests =
  testGroup
    "Oracle Deployment Tests"
    [ mkTestFor "Test Case 0.1: Deploy protocol with oracle and verify every oracle field is queryable" oracleDeployAndQuery
    ]
  where
    oracleDeployAndQuery :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    oracleDeployAndQuery TestInfo {..} = do
      waitNSlots_ 1000
      txBuildingContext <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (oracleParams, oracleRef, _oracleValue) <- runReaderT queryOracleParams txBuildingContext
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ "Oracle UTxO ref: " <> show oracleRef

      -- All five fields, not the three the inherited test checked: a field nobody asserts is a field
      -- the deployment can silently get wrong, and 'opDisputeDeposit' is the price of opening a
      -- dispute — a zero there would make the deposit, which is the only thing bounding dispute
      -- spam, free.
      assert (opAdminPkh oracleParams == userPlutusPkh (w1 testWallets))
      assert (not (opPaused oracleParams))
      assert (isNothing (opFeeConfig oracleParams))
      assert (opMinUTxOValue oracleParams == 1_000_000)
      assert (opDisputeDeposit oracleParams == 5_000_000)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Oracle deployment and query successful!"

oracleAdminTests :: (HasCallStack) => TestTree
oracleAdminTests =
  testGroup
    "Oracle Admin Tests"
    [ mkTestFor "Test Case 0.2: Pause and unpause protocol" pauseAndUnpause,
      mkTestFor "Test Case 0.3: Set fees and clear fees" setAndClearFees,
      mkTestFor "Test Case 0.4: Set min UTxO value" setMinUTxOValue,
      mkTestFor "Test Case 0.5: Reprice the dispute deposit" setDisputeDeposit,
      mkTestFor "Test Case 0.6: A non-admin cannot even build an oracle update (required signer)" nonAdminCannotBuild,
      mkTestFor "Test Case 0.7: A non-admin update signed by the attacker FAILS at the validator (O1)" nonAdminSignedUpdateFails,
      mkTestFor "Test Case 0.8: Every update returns the oracle NFT and its value untouched (O2)" updatePreservesOracleValue
    ]
  where
    pauseAndUnpause :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    pauseAndUnpause TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      params0 <- queryOracle ctx
      assert (not (opPaused params0))

      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1
      params1 <- queryOracle ctx
      assert (opPaused params1)

      _ <- adminInteraction ctx (w1 testWallets) UnpauseProtocolAction
      waitNSlots_ 1
      params2 <- queryOracle ctx
      assert (not (opPaused params2))

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Pause and unpause both landed."

    setAndClearFees :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    setAndClearFees TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      params0 <- queryOracle ctx
      assert (isNothing (opFeeConfig params0))

      let testFeeConfig = feeConfigPayingTo (w2 testWallets)
      _ <- adminInteraction ctx (w1 testWallets) (SetFeesAction (Just testFeeConfig))
      waitNSlots_ 1
      params1 <- queryOracle ctx
      -- Whole-record equality: the validator compares the whole datum, so a field the round-trip
      -- drops is a field the on-chain check would reject.
      assert (opFeeConfig params1 == Just testFeeConfig)

      _ <- adminInteraction ctx (w1 testWallets) (SetFeesAction Nothing)
      waitNSlots_ 1
      params2 <- queryOracle ctx
      assert (isNothing (opFeeConfig params2))

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Fees set and cleared."

    setMinUTxOValue :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    setMinUTxOValue TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      _ <- adminInteraction ctx (w1 testWallets) (SetMinUTxOValueAction 2_500_000)
      waitNSlots_ 1
      params1 <- queryOracle ctx
      assert (opMinUTxOValue params1 == 2_500_000)
      -- And nothing else moved. 'applyOracleAdminAction' is a record update, so a wrong field is a
      -- one-character mistake that type-checks.
      assert (opDisputeDeposit params1 == 5_000_000)

      _ <- adminInteraction ctx (w1 testWallets) (SetMinUTxOValueAction 1_000_000)
      waitNSlots_ 1
      params2 <- queryOracle ctx
      assert (opMinUTxOValue params2 == 1_000_000)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Min UTxO value set and reset."

    -- T-ATTEST-4's new admin action, which until now existed only in pure tests. Repricing the
    -- deposit is the one lever against dispute spam that does not need a redeployment.
    setDisputeDeposit :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    setDisputeDeposit TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      _ <- adminInteraction ctx (w1 testWallets) (SetDisputeDepositAction 25_000_000)
      waitNSlots_ 1
      params1 <- queryOracle ctx
      assert (opDisputeDeposit params1 == 25_000_000)
      assert (opMinUTxOValue params1 == 1_000_000)
      assert (opAdminPkh params1 == userPlutusPkh (w1 testWallets))

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Dispute deposit repriced, and nothing else moved."

    -- The production path's own refusal, which is a different layer from O1 and worth its own case:
    -- `updateOracleTX` demands the datum's admin as a signer, so a non-admin cannot produce a
    -- submittable transaction at all. This is the check that holds when the attacker uses the API.
    nonAdminCannotBuild :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    nonAdminCannotBuild TestInfo {..} = do
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1
      mustFail $ void $ adminInteraction ctx (w2 testWallets) PauseProtocolAction
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Non-admin update rejected before any script ran."

    -- And the check that holds when the attacker builds the transaction themselves: O1.
    nonAdminSignedUpdateFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    nonAdminSignedUpdateFails TestInfo {..} = do
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1
      mustFail $ void $ maliciousOracleUpdate ctx (w2 testWallets) PauseProtocolAction
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Attacker-signed oracle update rejected by the validator (O1)."

    -- O2 keeps the oracle UTxO where it is with what it holds. Without it an admin could pause the
    -- protocol and walk off with the oracle NFT in the same transaction, which would strand the
    -- protocol: every mint reads the oracle as a reference input, and there would be none.
    updatePreservesOracleValue :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    updatePreservesOracleValue TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_, _, valueBefore) <- runReaderT queryOracleParams ctx
      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1
      (_, _, valueAfter) <- runReaderT queryOracleParams ctx

      -- `queryOracleParams` finds the UTxO by the oracle NFT, so reaching this line at all proves
      -- the NFT is still at the oracle address; the equality is about the rest of the value.
      assert (valueAfter == valueBefore)
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ "Oracle value preserved across the update: " <> show valueAfter

oracleRotationTests :: (HasCallStack) => TestTree
oracleRotationTests =
  testGroup
    "Oracle Rotation Tests"
    [ mkTestFor "Test Case 0.9: Rotate the admin key, and the new admin can act (fix #2)" rotateAndNewAdminActs,
      mkTestFor "Test Case 0.10: The OLD admin cannot act after rotation (O1)" oldAdminCannotActAfterRotation,
      mkTestFor "Test Case 0.11: A non-admin cannot rotate the oracle to itself (O1)" nonAdminCannotSeizeOracle
    ]
  where
    -- Inherited fix #2, end to end. Before it, `OracleAdminAction` had no SetAdmin case and the
    -- validator's whole-datum equality preserved `opAdminPkh` by construction — rotation was not
    -- unimplemented, it was forbidden. These three cases are what make that a fix rather than a hope.
    rotateAndNewAdminActs :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    rotateAndNewAdminActs TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      params0 <- queryOracle ctx
      assert (opAdminPkh params0 == userPlutusPkh (w1 testWallets))

      _ <- adminInteraction ctx (w1 testWallets) (RotateAdminAction (User.userPkh (w2 testWallets)))
      waitNSlots_ 1
      params1 <- queryOracle ctx
      assert (opAdminPkh params1 == userPlutusPkh (w2 testWallets))

      -- The rotation is only real if the new key can actually act. Asserting the datum field alone
      -- would pass even if the validator refused every subsequent update.
      _ <- adminInteraction ctx (w2 testWallets) PauseProtocolAction
      waitNSlots_ 1
      params2 <- queryOracle ctx
      assert (opPaused params2)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Admin rotated, and the new admin acted."

    oldAdminCannotActAfterRotation :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    oldAdminCannotActAfterRotation TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      _ <- adminInteraction ctx (w1 testWallets) (RotateAdminAction (User.userPkh (w2 testWallets)))
      waitNSlots_ 1

      -- The malicious builder, because the production path would ask w2 to sign and w1 cannot. What
      -- must reject this is the validator reading the NEW admin out of the datum.
      mustFail $ void $ maliciousOracleUpdate ctx (w1 testWallets) UnpauseProtocolAction
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "The rotated-out admin was rejected by the validator (O1)."

    -- The attack rotation exists to enable: seizing the oracle. If O1 did not hold, any wallet could
    -- name itself admin and own every protocol parameter from then on.
    nonAdminCannotSeizeOracle :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    nonAdminCannotSeizeOracle TestInfo {..} = do
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1
      mustFail $
        void $
          maliciousOracleUpdate ctx (w3 testWallets) (RotateAdminAction (User.userPkh (w3 testWallets)))
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Oracle seizure rejected (O1)."

oracleNFTTests :: (HasCallStack) => TestTree
oracleNFTTests =
  testGroup
    "Oracle NFT Policy Tests"
    [ mkTestFor "Test Case 0.12: Minting the oracle NFT with an extra token fails (F-22a)" oracleExtraTokenMintFails,
      mkTestFor "Test Case 0.13: Minting the oracle NFT with a non-empty token name fails" oracleWrongNameMintFails
    ]
  where
    oracleExtraTokenMintFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    oracleExtraTokenMintFails TestInfo {..} =
      mustFail $ void $ maliciousMintOracleNFTWithExtraToken (w1 testWallets)

    oracleWrongNameMintFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    oracleWrongNameMintFails TestInfo {..} =
      mustFail $ void $ maliciousMintOracleNFTWrongName (w1 testWallets)

-- | A fee configuration paying a given wallet. The two amounts are deliberately different, so a
-- transposition between 'fcProfileCreationFee' and 'fcAttestationFee' is a failed assertion rather
-- than a coincidence.
feeConfigPayingTo :: User -> FeeConfig
feeConfigPayingTo w =
  FeeConfig
    { fcFeeAddress = addressToPlutus (User.userChangeAddress w),
      fcProfileCreationFee = 2_000_000,
      fcAttestationFee = 1_500_000
    }
