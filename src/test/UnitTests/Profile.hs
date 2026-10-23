{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The claim, in a real ledger — F1 check 8's "un claim de script-credential reușit și unul respins".
--
-- The protocol's whole identity rule is one sentence: /prove you can spend as that credential/. There
-- is no registry, no allow-list and no attestation of who you are; a profile that claims a DRep id or
-- a committee credential has to show, in the same transaction, that it controls it. @Mc3@ is that
-- rule, and these are the cases that hold it up.
--
-- __Why half of these need a malicious builder.__ 'Palmares.TxBuilding.Operations.claimProofSkeleton'
-- attaches the proof itself — a required signer for a key credential, a spend of the script's own
-- UTxO for a script one — so the API physically cannot produce a claim with no proof. A @mustFail@ on
-- the API's refusal would pass with @Mc3@ deleted. 'TestRuns.maliciousClaimWithoutControl' is the
-- same transaction with the proof removed, and it is what the @Mc3@ cases below use.
--
-- __Test Case 1.3 asserts a FIXED vulnerability and is deliberately inverted.__ It was written as a
-- success: a claim proven by spending a UTxO whose __staking__ credential is the claimed script.
-- 'Palmares.Onchain.Utils.checkCredentialControl' used to accept that, and it was a critical hole —
-- the ledger never witnesses the staking half of an input address, so anyone could put any script
-- hash in the staking part of their own address and claim that script's identity. The check now
-- reads the __payment__ half only, because spending authenticates the payment credential and nothing
-- else. The case therefore has to fail, and it fails on the old behaviour by passing.
module UnitTests.Profile
  ( profileTests,
  )
where

import Control.Monad (void)
import GHC.Stack
import GeniusYield.Test.Clb
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder
import GeniusYield.TxBuilder.User qualified as User
import GeniusYield.Types
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types (ProfileType (..))
import Palmares.Onchain.CIP68 (extra)
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.TxBuilding.Conversions (claimCredentialToText, profileDataToMetadataFields)
import Palmares.TxBuilding.Lookups (getAttestationDatumAndValue, getProfileStateDatumAndValue)
import PlutusLedgerApi.V3 qualified as V3
import Test.Fixtures (committeeProfileData, communityProfileData, drepBProfileData, drepProfileData, orgProfileData)
import Test.Helpers (assert, failedWithTrace)
import Test.Tasty
import TestRuns
  ( deployValidators,
    maliciousClaimWithoutControl,
    maliciousMintProfileWithBurn,
    maliciousMintProfileWithExtraToken,
    profileInteraction,
    sendAdaToAddress,
    userPlutusPkh,
  )

profileTests :: (HasCallStack) => TestTree
profileTests =
  testGroup
    "Profile Claim Tests"
    [ mkTestFor "Test Case 1.1: a key credential claims a profile with an extra signatory" keyCredentialClaim,
      mkTestFor "Test Case 1.2: a script credential claims a profile by spending a UTxO at its own address" scriptCredentialClaim,
      mkTestFor "Test Case 1.3: a script credential claims by spending a UTxO whose STAKING credential is the script" stakingHalfClaimFails,
      mkTestFor "Test Case 1.4: a profile with no credential (Community) mints without a claim" unclaimedProfileMints,
      mkTestFor "Test Case 1.5: a claim without the signatory FAILS (Mc3)" claimWithoutSignatoryFails,
      mkTestFor "Test Case 1.6: a claim naming a script whose UTxO is not spent FAILS (Mc3)" claimWithoutScriptSpendFails,
      mkTestFor "Test Case 1.7: a claim whose minted value carries an extra token FAILS (Mp2)" claimWithExtraTokenFails,
      mkTestFor "Test Case 1.8: a claim that burns a token alongside the mint FAILS (Mp2)" claimWithBurnFails,
      mkTestFor "Test Case 1.9: the same credential claimed by two wallets both succeed — uniqueness is a read fact" sameCredentialTwice,
      mkTestFor "Test Case 1.10: a script credential with no UTxO at its own address is refused before building" scriptWithNoUtxoRefused
    ]
  where
    -- A key credential's proof is a REQUIRED SIGNER, over and above the witnesses the inputs already
    -- need: @Mc3@ reads @txInfoSignatories@, which carries only the keys the transaction declares.
    -- So the claim is real precisely because `claimProofSkeleton` added a signatory that the mint
    -- would not otherwise have had — that is what Test Case 1.5 removes.
    keyCredentialClaim :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    keyCredentialClaim TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      let claimed = V3.PubKeyCredential (userPlutusPkh (w1 testWallets))
      (_txId, profileAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimProfileAction PersonDRep drepProfileData)
          Nothing
      waitNSlots_ 1

      (datum, _value) <- getProfileStateDatumAndValue profileAC
      assert (OnchainTypes.profileKind (extra datum) == OnchainTypes.PersonDRep)

      -- ADR 0003: the binding is a SECOND transaction and its own record. The profile carries no
      -- credential field any more, so what this asserts is the record that landed.
      (_t2, claimAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimCredentialAction profileAC (claimCredentialToText claimed) Nothing drepProfileData)
          Nothing
      waitNSlots_ 1

      -- The credential that LANDED, not "the transaction did not throw". A binding whose credential
      -- is dropped on the way into the datum is a profile the read layer would show as unclaimed
      -- while the claimant believes it is verified.
      (claimDatum, _) <- getAttestationDatumAndValue claimAC
      assert (OnchainTypes.attestationCredential (extra claimDatum) == Just claimed)
      assert (OnchainTypes.attestationKind (extra claimDatum) == OnchainTypes.CredentialClaim)
      -- And self-issued, which is @Mc1@ and what makes the record mean "this profile bound itself".
      assert (OnchainTypes.attestationSubject (extra claimDatum) == OnchainTypes.attestationIssuer (extra claimDatum))

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A key credential was bound to a profile and recorded." 

    -- The successful half of F1 check 8. A native script with no conditions at all, so the ledger
    -- lets anyone spend its UTxOs: the point is not the script's logic, it is that an ORGANISATION
    -- acting through a script can hold a profile at all. 'WitnessSimpleScript' is what carries it,
    -- and until T-ATTEST-6 the off-chain builder hardcoded a key witness and made this impossible.
    scriptCredentialClaim :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    scriptCredentialClaim TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      scriptAddr <- scriptAddress' openScriptHash
      sendAdaToAddress (w1 testWallets) scriptAddr 5_000_000
      waitNSlots_ 1

      let claimed = scriptCredential
      (_txId, profileAC) <-
        profileInteraction ctx (w1 testWallets) (ClaimProfileAction Organization orgProfileData) Nothing
      waitNSlots_ 1

      (_t2, claimAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( ClaimCredentialAction
              profileAC
              (claimCredentialToText claimed)
              (Just (WitnessSimpleScript openScript))
              orgProfileData
          )
          Nothing
      waitNSlots_ 1

      (claimDatum, _) <- getAttestationDatumAndValue claimAC
      assert (OnchainTypes.attestationCredential (extra claimDatum) == Just claimed)
      -- And the proof was consumed: the script's UTxO is gone, which is the whole content of "it
      -- proved control by spending".
      assert . (== 0) =<< utxoCountAt scriptAddr

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A script credential was claimed by spending its own UTxO."

    -- THE INVERTED CASE. The claimed credential is a script; the proof offered is a UTxO at an
    -- address whose PAYMENT half is the claimant's own key and whose STAKING half is that script.
    -- The ledger authenticates the payment half and never looks at the staking half of an input, so
    -- this proves nothing — and before the fix `checkCredentialControl` accepted it, which made every
    -- script credential claimable by anyone who could write a hash into their own address.
    --
    -- A malicious builder because the production path cannot even offer this proof:
    -- `claimProofSkeleton` looks up UTxOs by PAYMENT credential, so it would never find this one and
    -- would refuse with @ScriptCredentialHasNoUtxo@ — a build-time refusal that says nothing about
    -- the on-chain rule. On the old on-chain code this test passes, which is how it fails.
    stakingHalfClaimFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    stakingHalfClaimFails TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      nid <- networkId
      let stakingDressedAddr =
            addressFromCredential
              nid
              (GYPaymentCredentialByKey (User.userPaymentPkh (w1 testWallets)))
              (Just (GYStakeCredentialByScript openScriptHash))
      sendAdaToAddress (w1 testWallets) stakingDressedAddr 5_000_000
      waitNSlots_ 1
      proofRef <- someUtxoRefAt stakingDressedAddr

      (_txId, profileAC) <-
        profileInteraction ctx (w1 testWallets) (ClaimProfileAction Organization orgProfileData) Nothing
      waitNSlots_ 1

      mustFailWith (failedWithTrace "Mc3") $
        void $
          maliciousClaimWithoutControl
            ctx
            (w1 testWallets)
            profileAC
            scriptCredential
            (profileDataToMetadataFields orgProfileData)
            (Just proofRef)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A staking-half binding was rejected (Mc3)."

    -- A profile need not correspond to any on-chain credential, and that is not a hole: @Mc3@ is
    -- @True@ for 'Nothing' by construction, and the read layer must present such a profile as
    -- unclaimed rather than verified.
    unclaimedProfileMints :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    unclaimedProfileMints TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_txId, profileAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimProfileAction Community communityProfileData)
          Nothing
      waitNSlots_ 1

      (datum, _value) <- getProfileStateDatumAndValue profileAC
      assert (OnchainTypes.profileKind (extra datum) == OnchainTypes.Community)
      -- There is no credential field to be 'Nothing' any more (ADR 0003). "Unclaimed" is now the
      -- ABSENCE of a CredentialClaim record, and four of the six kinds never create one — which is
      -- why this test is one transaction while 1.1 and 1.2 are two.

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A Community profile minted, with no binding record at all." 

    -- The redeemer names w2's key credential and the transaction carries NO required signer at all —
    -- not a wrong one, none. So the failure cannot be the ledger complaining about a missing witness;
    -- it is the policy reading an empty @txInfoSignatories@. Delete @Mc3@ and any wallet can mint a
    -- profile claiming to be any DRep.
    claimWithoutSignatoryFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    claimWithoutSignatoryFails TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_txId, profileAC) <-
        profileInteraction ctx (w1 testWallets) (ClaimProfileAction PersonDRep drepProfileData) Nothing
      waitNSlots_ 1

      mustFailWith (failedWithTrace "Mc3") $
        void $
          maliciousClaimWithoutControl
            ctx
            (w1 testWallets)
            profileAC
            (V3.PubKeyCredential (userPlutusPkh (w2 testWallets)))
            (profileDataToMetadataFields drepProfileData)
            Nothing

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A binding to someone else's key credential was rejected (Mc3)."

    -- The script credential's UTxO EXISTS and is spendable — it is funded two lines up — and the
    -- transaction simply does not spend it. That is the precise shape of the script-credential rule:
    -- not "the script exists", but "this transaction spent something it governs".
    claimWithoutScriptSpendFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    claimWithoutScriptSpendFails TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      scriptAddr <- scriptAddress' openScriptHash
      sendAdaToAddress (w1 testWallets) scriptAddr 5_000_000
      waitNSlots_ 1

      (_txId, profileAC) <-
        profileInteraction ctx (w1 testWallets) (ClaimProfileAction Committee committeeProfileData) Nothing
      waitNSlots_ 1

      mustFailWith (failedWithTrace "Mc3") $
        void $
          maliciousClaimWithoutControl
            ctx
            (w1 testWallets)
            profileAC
            scriptCredential
            (profileDataToMetadataFields committeeProfileData)
            Nothing

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A script binding that spent nothing was rejected (Mc3)."

    -- @Mp2@ is exact-mint: the transaction mints the CIP-68 pair and nothing else. An extra token
    -- under the protocol's own symbol is how a profile id could be forged — the ref token IS the
    -- profile and the user token IS its authority, so a policy that would mint a third thing in the
    -- same breath is a policy that can mint authority nobody asked for.
    claimWithExtraTokenFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    claimWithExtraTokenFails TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      mustFailWith (failedWithTrace "Mp2") $
        void $
          maliciousMintProfileWithExtraToken
            ctx
            (w1 testWallets)
            (ClaimProfileAction Community communityProfileData)
            "EXTRA"

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A profile mint with an extra token was rejected (Mp2)."

    -- The other half of @Mp2@, and the one that matters on a chain where nothing is supposed to burn:
    -- a mint that could also destroy a user token could destroy somebody's authority instrument
    -- while minting its own. The token burned here is a real profile's, created in the same test.
    claimWithBurnFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    claimWithBurnFails TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_txId, firstProfileAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimProfileAction Community communityProfileData)
          Nothing
      waitNSlots_ 1

      mustFailWith (failedWithTrace "Mp2") $
        void $
          maliciousMintProfileWithBurn
            ctx
            (w1 testWallets)
            (ClaimProfileAction Organization orgProfileData)
            firstProfileAC

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A profile mint that also burned a user token was rejected (Mp2)."

    -- REVIEW FOCUS ITEM 2, and it asserts the documented behaviour rather than a wish. Nothing on
    -- chain makes a credential unique: @Mc3@ asks whether THIS transaction controls the credential,
    -- which two different wallets can both answer yes to for a permissionless script — and for a key
    -- credential, the key's owner can claim twice. Uniqueness is therefore a READ fact: the API marks
    -- a credential claimed by more than one profile as @contested@ (T-ATTEST-9's test), and that is
    -- the only place it can be enforced without an index UTxO every claim has to contend for.
    sameCredentialTwice :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    sameCredentialTwice TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      scriptAddr <- scriptAddress' openScriptHash
      -- Two UTxOs, because the first claim SPENDS one: the proof is consumed, so a second claimant
      -- needs its own.
      sendAdaToAddress (w1 testWallets) scriptAddr 5_000_000
      sendAdaToAddress (w2 testWallets) scriptAddr 5_000_000
      waitNSlots_ 1

      (_txId1, profileA) <- profileInteraction ctx (w1 testWallets) (ClaimProfileAction Organization orgProfileData) Nothing
      waitNSlots_ 1
      (_txId2, profileB) <- profileInteraction ctx (w2 testWallets) (ClaimProfileAction Organization drepBProfileData) Nothing
      waitNSlots_ 1

      let bind pid pdata =
            ClaimCredentialAction
              pid
              (claimCredentialToText scriptCredential)
              (Just (WitnessSimpleScript openScript))
              pdata

      (_t3, claimA) <- profileInteraction ctx (w1 testWallets) (bind profileA orgProfileData) Nothing
      waitNSlots_ 1
      (_t4, claimB) <- profileInteraction ctx (w2 testWallets) (bind profileB drepBProfileData) Nothing
      waitNSlots_ 1

      -- Two distinct profiles, both carrying a binding record for the same credential. If the chain
      -- enforced uniqueness one of these transactions would have failed; it does not, so the read
      -- layer must. ADR 0003 does not change that — it changes only where the binding lives.
      assert (profileA /= profileB)
      (datumA, _) <- getAttestationDatumAndValue claimA
      (datumB, _) <- getAttestationDatumAndValue claimB
      assert (OnchainTypes.attestationCredential (extra datumA) == Just scriptCredential)
      assert (OnchainTypes.attestationCredential (extra datumB) == Just scriptCredential)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "One credential, two profiles, both on chain."

    -- Review Focus item 1, the BUILD-time half (its message is pinned in 'UnitTests.WritePath').
    -- A Plutus script that only votes or withdraws holds no UTxO at its own address, so it cannot
    -- prove control in one transaction however good its witness. The lookup happens before anything
    -- is built, which is the point: left to the balancer this is an unreadable failure, and here it
    -- is a 400 naming the script.
    --
    -- Plain 'mustFail' and no trace code, because NO SCRIPT RUNS: the refusal is
    -- @ScriptCredentialHasNoUtxo@, thrown by `claimProofSkeleton`. A `failedWithTrace` assertion here
    -- would never match and the test would pass while asserting nothing.
    scriptWithNoUtxoRefused :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    scriptWithNoUtxoRefused TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_txId, profileAC) <-
        profileInteraction ctx (w1 testWallets) (ClaimProfileAction Committee committeeProfileData) Nothing
      waitNSlots_ 1

      -- Deliberately NOT funded. The profile mint above succeeds, because ADR 0003 made it claim
      -- nothing — so this test now isolates the BINDING, which is the operation the lookup guards.
      mustFail $
        void $
          profileInteraction
            ctx
            (w1 testWallets)
            ( ClaimCredentialAction
                profileAC
                (claimCredentialToText scriptCredential)
                (Just (WitnessSimpleScript openScript))
                committeeProfileData
            )
            Nothing

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A script credential with no UTxO was refused before building."

    utxoCountAt :: (GYTxQueryMonad m) => GYAddress -> m Int
    utxoCountAt addr = length . utxosToList <$> utxosAtAddresses [addr]

    someUtxoRefAt :: (GYTxQueryMonad m) => GYAddress -> m GYTxOutRef
    someUtxoRefAt addr = do
      utxos <- utxosAtAddresses [addr]
      case utxosToList utxos of
        (u : _) -> return (utxoRef u)
        [] -> error "someUtxoRefAt: no UTxO at the address"

-- | A native script with no conditions: @RequireAllOf []@ is satisfied by every transaction, so
-- anyone may spend a UTxO at its address.
--
-- That is the right fixture here and not a weakness of the test. What @Mc3@ checks is that the
-- transaction spent an input the claimed script governs; whether the script's own condition is a
-- multisig, a timelock or nothing at all is the script's business, already settled by the ledger
-- before our policy runs. A @RequireSignature@ script would test the ledger's native-script
-- evaluator, which is not ours.
openScript :: GYSimpleScript
openScript = RequireAllOf []

openScriptHash :: GYScriptHash
openScriptHash = hashSimpleScript openScript

-- | 'openScript' as a claimable credential.
scriptCredential :: V3.Credential
scriptCredential = V3.ScriptCredential (scriptHashToPlutus openScriptHash)
