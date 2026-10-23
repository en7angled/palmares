{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant $" #-}
module Palmares.TxBuilding.Transactions where

import Cardano.Api.Ledger qualified as Ledger
import Cardano.Api.Shelley qualified as Api
import Control.Lens ((.~))
import Control.Monad (when)
import Control.Monad.Reader
import Data.Function ((&))
import Data.Set qualified as Set
import Data.Text
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.Onchain.Protocol.Types (OracleParams (..), oracleParamsAreWellFormed)
import Text.Printf (printf)
import Text.Printf qualified as Printf
import Palmares.TxBuilding.Context (DeployedScriptsContext (..), ProviderCtx (..), TxBuildingContext (..), ctxProviders, deployedScriptsCtx, getNetworkId, providerCtx, runTx, runTx')
import Palmares.TxBuilding.Interactions
import Palmares.TxBuilding.Skeletons
import Palmares.TxBuilding.Utils
import Palmares.TxBuilding.Validators
import Palmares.Utils

------------------------------------------------------------------------------------------------

-- * Witnesses

------------------------------------------------------------------------------------------------

-- | The vkey witnesses of a signed transaction, as the witness SET the API's @tx_wit@ field takes.
--
-- 'makeSignedTransaction' read backwards, and the same expression cardano-api's own
-- @makeSignedTransaction@ uses to build that set — copied from it rather than invented.
--
-- __Only the vkey witnesses.__ A signed transaction's witness set also carries scripts, datums and
-- redeemers, and every one of those is reconstructed from @tx_unsigned@ on the far side and ignored
-- here. Carrying them would change nothing on chain and would make a signer's output visibly unlike
-- a wallet's, which is the failure the @admin sign-tx@ command exists to avoid: an operator who
-- compares the two and concludes the signer is broken.
--
-- __This lives in the library and not in @admin@ so that a test can reach it.__ A cabal test-suite
-- cannot import an executable's modules, so while this sat in @admin/Main.hs@ the only test
-- available was one that pinned a COPY of the expression — which passes forever while the command
-- rots. Three lines of move buy a test that fails when the command breaks.
keyWitnessesOf :: GYTx -> GYTxWitness
keyWitnessesOf signed =
  txWitFromLedger $
    Ledger.mkBasicTxWits
      & Ledger.addrTxWitsL
        .~ Set.fromList [w | Api.ShelleyKeyWitness _ w <- Api.getTxWitnesses (txToApi signed)]

-- | Hex-encoded CBOR of a witness set — the inverse of the @txWitFromHex@ that parses @tx_wit@.
--
-- __Atlas ships the decoder for this shape and no encoder__, which is why this exists at all:
-- @GeniusYield.Types.Tx@ exports @txWitFromHexBS@, @txWitFromHex@, @txWitFromLedger@,
-- @txWitToLedger@ and @txWitToKeyWitnessApi@, and nothing that goes the other way.
--
-- __No protocol version to get wrong, and no base16 of our own.__ @AlonzoTxWits@ is a @MemoBytes@,
-- so its plain @ToCBOR@ emits the very bytes the ledger produced for that value rather than
-- re-encoding it, and @serializeAsHexText@ is the ledger's own hex codec over them. Atlas's decoder
-- reads at @eraProtVerHigh \@ConwayEra@; there is nothing here for that choice to disagree with.
txWitToHex :: GYTxWitness -> Text
txWitToHex = Ledger.serializeAsHexText . txWitToLedger

------------------------------------------------------------------------------------------------

-- * Transaction Submitting

------------------------------------------------------------------------------------------------
submitTxAndWaitForConfirmation :: Bool -> GYProviders -> GYTx -> IO GYTxId
submitTxAndWaitForConfirmation wait ctxProviders gyTx = do
  gyTxId <- gySubmitTx ctxProviders gyTx
  printf (yellowColorString "Submitted transaction: \n\t %s") gyTxId
  when wait do
    putStrLn (yellowColorString "Waiting for confirmation ...")
    gyAwaitTxConfirmed ctxProviders (GYAwaitTxParameters 30 10000000 1) gyTxId
    printf (greenColorString "Confirmed:  \n\t %s") gyTxId
  return gyTxId

submitTx :: (MonadReader TxBuildingContext m, MonadIO m) => GYTx -> m GYTxId
submitTx gyTx = do
  providerCtx <- asks providerCtx
  gyTxId <- liftIO $ gySubmitTx (ctxProviders providerCtx) gyTx
  liftIO $ printf (yellowColorString "Submitted transaction: \n\t %s") gyTxId
  return gyTxId

------------------------------------------------------------------------------------------------

-- * Transaction Building

------------------------------------------------------------------------------------------------

-- | Builds a transaction body from an interaction
interactionToTxBody ::
  (MonadReader TxBuildingContext m, MonadIO m) =>
  Interaction ->
  m (GYTxBody, Maybe GYAssetClass)
interactionToTxBody i@Interaction {..} = do
  TxBuildingContext {..} <- ask
  let builderMonadSkeleton = runReaderT (interactionToTxSkeleton i) deployedScriptsCtx
  liftIO $ runTx providerCtx (usedAddresses userAddresses) (changeAddress userAddresses) (reservedCollateral userAddresses) builderMonadSkeleton

-- | Builds an unsigned transaction from an interaction
interactionToUnsignedTx :: (MonadReader TxBuildingContext m, MonadIO m) => Interaction -> m GYTx
interactionToUnsignedTx = fmap (unsignedTx . fst) . interactionToTxBody

-- | Builds a hex encoded CBOR from an interaction
interactionToHexEncodedCBOR :: (MonadReader TxBuildingContext m, MonadIO m) => Interaction -> m String
interactionToHexEncodedCBOR = (txToHex <$>) . interactionToUnsignedTx

------------------------------------------------------------------------------------------------

-- * Transaction Running

------------------------------------------------------------------------------------------------

addressFromSkey :: ProviderCtx -> GYExtendedPaymentSigningKey -> GYAddress
addressFromSkey pCtx skey =
  let nid = getNetworkId pCtx
   in addressFromPaymentSigningKey nid skey

pkhFromSkey :: GYExtendedPaymentSigningKey -> GYPaymentKeyHash
pkhFromSkey = pkhFromExtendedSkey

runActionWithPK :: TxBuildingContext -> GYExtendedPaymentSigningKey -> ActionType -> Maybe GYAddress -> IO (GYTxId, Maybe GYAssetClass)
runActionWithPK txBuildingCtx@TxBuildingContext {..} skey action optionalRecipient = do
  let my_addr = addressFromSkey providerCtx skey
  let userAddrs = UserAddresses [my_addr] my_addr Nothing
  let interaction = Interaction action userAddrs optionalRecipient
  putStrLn (yellowColorString "Building transaction...")
  (txBody, mAssetClass) <- runReaderT (interactionToTxBody interaction) txBuildingCtx
  let txSigned = signGYTxBody txBody [skey]
  putStrLn $ yellowColorString ("Built and signed by: \n\t" <> Data.Text.unpack (addressToText my_addr))
  txId <- submitTxAndWaitForConfirmation True (ctxProviders providerCtx) txSigned
  return (txId, mAssetClass)

------------------------------------------------------------------------------------------------

-- * Reference Script Deployment

------------------------------------------------------------------------------------------------

-- | Deploy a single reference script and return its hash and the TxOutRef.
deployReferenceScript :: ProviderCtx -> GYScript 'PlutusV3 -> GYExtendedPaymentSigningKey -> IO (GYScriptHash, GYTxOutRef)
deployReferenceScript providerCtx script skey = do
  let my_addr = addressFromSkey providerCtx skey
  putStrLn $ yellowColorString "Deploying reference script"
  putStrLn $ yellowColorString $ "Deployed Script Hash: \n\t" <> Printf.printf "%s" (scriptHash script)
  putStrLn $ yellowColorString $ "Deployed to Address: \n\t" <> Printf.printf "%s" (addressToText my_addr)
  txBody <- runTx' providerCtx [my_addr] my_addr Nothing (addRefScriptToAddressSkeleton my_addr script)
  let txSigned = signGYTxBody txBody [skey]
  putStrLn $ yellowColorString ("Built and signed by: \n\t" <> Data.Text.unpack (addressToText my_addr))
  gyTxId <- submitTxAndWaitForConfirmation True (ctxProviders providerCtx) txSigned
  return (scriptHash script, txOutRefFromTuple (gyTxId, 0))

-- | Full deployment flow for all protocol scripts and the oracle.
-- Steps:
--   1. Deploy oracle validator reference script
--   2. Mint oracle NFT and lock initial OracleParams at oracle validator
--   3. Deploy the profiles, attestations and disputes validator reference scripts
--   4. Compile minting policy with oracle NFT asset class and deploy its reference script
deployReferenceScripts :: ProviderCtx -> GYExtendedPaymentSigningKey -> IO DeployedScriptsContext
deployReferenceScripts providerCtx skey = do
  let my_pkh = pkhFromSkey skey

  -- Step 1: Deploy oracle validator reference script
  putStrLn $ yellowColorString "=== Step 1: Deploy Oracle Validator ==="
  ov <- deployReferenceScript providerCtx oracleValidatorGY skey

  -- Step 2: Mint oracle NFT and lock initial OracleParams
  putStrLn $ yellowColorString "=== Step 2: Mint Oracle NFT and Lock Initial OracleParams ==="
  oracleNFTAC <- mintOracleNFTAndLockDatum providerCtx skey my_pkh

  -- Step 3: Deploy spending validator reference scripts
  putStrLn $ yellowColorString "=== Step 3: Deploy Spending Validators ==="
  pv <- deployReferenceScript providerCtx profilesValidatorGY skey
  av <- deployReferenceScript providerCtx attestationsValidatorGY skey
  dv <- deployReferenceScript providerCtx disputesValidatorGY skey

  -- Step 4: Compile and deploy the minting policy (parameterized by oracle NFT)
  putStrLn $ yellowColorString "=== Step 4: Compile and Deploy Minting Policy ==="
  let mpGY = compileMintingPolicy (assetClassToPlutus oracleNFTAC)
  mp <- deployReferenceScript providerCtx mpGY skey

  return
    DeployedScriptsContext
      { mintingPolicyHashAndRef = mp,
        profilesValidatorHashAndRef = pv,
        attestationsValidatorHashAndRef = av,
        disputesValidatorHashAndRef = dv,
        oracleValidatorHashAndRef = ov,
        oracleNFTAssetClass = oracleNFTAC
      }

-- | Mint the oracle NFT using a one-shot policy and lock the initial oracle datum.
mintOracleNFTAndLockDatum :: ProviderCtx -> GYExtendedPaymentSigningKey -> GYPaymentKeyHash -> IO GYAssetClass
mintOracleNFTAndLockDatum providerCtx skey adminPKH = do
  let nid = getNetworkId providerCtx
  let my_addr = addressFromSkey providerCtx skey
  let providers = ctxProviders providerCtx

  -- Build initial oracle params. Outside the builder, because they are a function of `adminPKH`
  -- alone and because the assertion below needs `IO`: `GYTxBuilderMonadIO` has no `MonadIO`
  -- instance, which is the builder refusing to let arbitrary effects into transaction construction.
  let initialOracleParams =
        OracleParams
          { opAdminPkh = paymentKeyHashToPlutus adminPKH,
            opPaused = False,
            opFeeConfig = Nothing,
            opMinUTxOValue = 1000000,
            -- A starting price, not a constant: the oracle admin reprices it with SetDisputeDepositAction.
            opDisputeDeposit = 5000000,
            -- 30 days, the D-A default, and a starting value exactly like the deposit above:
            -- `admin set-dispute-timeout` retimes it for NEW disputes. Long on purpose — after
            -- this, ANYONE may close an undecided dispute, so the number is how much time the
            -- oracle admin is given to rule before a stranger may clear a stale accusation.
            opDisputeTimeoutMs = 2592000000
          }

  -- `O6` is the one rule that never runs at deployment. `oracleParamsAreWellFormed` gates every
  -- UPDATE through the Oracle Validator, and nothing at all gates THIS datum, so a wrong literal
  -- above would be live from block one with no transaction to refuse it (audit OC-12). Asserted
  -- here rather than trusted, because the one place a constant is written is the one place it can
  -- be checked for free.
  when (not (oracleParamsAreWellFormed initialOracleParams)) $
    fail "mintOracleNFTAndLockDatum: the initial OracleParams would not pass O6"

  -- Build the transaction; also return the oracle NFT asset class from inside the builder.
  (txBody, oracleNFTAC) <- runGYTxBuilderMonadIO nid providers [my_addr] my_addr Nothing $ do
    -- Find a seed UTxO for the one-shot policy
    seedGYRef <- someUTxOWithoutRefScript
    let seedPlutus = txOutRefToV3Plutus seedGYRef

    -- Compile the one-shot oracle NFT policy
    let oracleNFTPolicyGY = compileOracleNFTPolicy seedPlutus
    let oracleNFTMPId = mintingPolicyId oracleNFTPolicyGY
    let oracleNFTTN = "" -- empty token name for the NFT
    let theOracleNFTAC = GYToken oracleNFTMPId oracleNFTTN

    -- Spend seed UTxO
    let spendSeed = mustHaveInput (GYTxIn seedGYRef GYTxInWitnessKey)

    -- Mint oracle NFT
    let mp = GYMintScript @'PlutusV3 oracleNFTPolicyGY
    let gyRedeemer = redeemerFromPlutusData ()
    let mintNFT = mustMint mp gyRedeemer oracleNFTTN 1

    -- Lock oracle NFT + datum at oracle validator address
    lockOutput <- txMustLockStateWithInlineDatumAndValue oracleValidatorGY initialOracleParams (valueSingleton theOracleNFTAC 1 <> valueFromLovelace 3500000)

    body <- buildTxBody $ mconcat [spendSeed, mintNFT, lockOutput]
    return (body, theOracleNFTAC)

  let txSigned = signGYTxBody txBody [skey]
  _gyTxId <- submitTxAndWaitForConfirmation True (ctxProviders providerCtx) txSigned

  putStrLn $ yellowColorString $ "Oracle NFT AssetClass: " <> show oracleNFTAC
  return oracleNFTAC
