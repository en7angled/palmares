-- | Datum parsing, GY/Plutus conversions, and small helpers for TxBuilding.
module Palmares.TxBuilding.Utils where

import Cardano.Api (Key (getVerificationKey), castVerificationKey)
import Control.Monad.Except (throwError)
import Data.Text
import Data.Text.IO qualified
import GeniusYield.TxBuilder.Class (enclosingSlotFromTime', slotToBeginTime)
import GeniusYield.TxBuilder.Errors (GYTxMonadException (GYApplicationException))
import GeniusYield.TxBuilder.Query.Class (GYTxQueryMonad)
import GeniusYield.Types (GYAddress, GYAssetClass (..), GYDatum, GYExtendedPaymentSigningKey, GYMintingPolicyId, GYNetworkId (..), GYOutDatum (..), GYPaymentKeyHash, GYSlot, GYTokenName, GYTxOutRef, GYUTxO, GYValue, mintingPolicyIdFromCurrencySymbol, paymentKeyHash, tokenNameFromPlutus, txOutRefToPlutus, utxoOutDatum, utxoValue, valueAssetClass, valueToPlutus)
import GeniusYield.Types.Address (addressFromPaymentKeyHash)
import GeniusYield.Types.Datum (datumToPlutus')
import GeniusYield.Types.Key (extendedPaymentSigningKeyToApi, paymentVerificationKeyFromApi)
import GeniusYield.Types.Time (timeFromPlutus, timeToPlutus)
import GeniusYield.Types.Wallet
import Palmares.Onchain.CIP68 (CIP68Datum)
import Palmares.Onchain.Protocol qualified as Onchain
import Palmares.Onchain.Protocol.Types (OnchainAchievement, OracleParams)
import PlutusLedgerApi.V1.Tx qualified as V1
import PlutusLedgerApi.V1.Value (flattenValue)
import PlutusLedgerApi.V3
import PlutusLedgerApi.V3.Tx qualified as V3
import System.Directory.Extra
import System.Exit (die)
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.Utils

------------------------------------------------------------------------------------------------

-- * Utilities

------------------------------------------------------------------------------------------------

-- | Extract the payment key hash from an extended payment signing key.
pkhFromExtendedSkey :: GYExtendedPaymentSigningKey -> GYPaymentKeyHash
pkhFromExtendedSkey skey =
  let vkey = Cardano.Api.getVerificationKey $ extendedPaymentSigningKeyToApi skey
   in paymentKeyHash (paymentVerificationKeyFromApi (castVerificationKey vkey))

addressFromPaymentSigningKey :: GYNetworkId -> GYExtendedPaymentSigningKey -> GYAddress
addressFromPaymentSigningKey nid skey = addressFromPaymentKeyHash nid (pkhFromExtendedSkey skey)

-- | Extract the single non-ADA asset class from a GYValue (protocol UTxOs
-- hold exactly one NFT + ADA). Returns 'Nothing' if there is no non-ADA asset.
extractNFTAssetClass :: GYValue -> Maybe GYAssetClass
extractNFTAssetClass v =
  case [(cs, tn) | (cs, tn, _) <- flattenValue (valueToPlutus v), cs /= adaSymbol] of
    [(cs, tn)] ->
      case (mintingPolicyIdFromCurrencySymbol cs, tokenNameFromPlutus tn) of
        (Right mpid, Just tn') -> Just (GYToken mpid tn')
        _ -> Nothing
    _ -> Nothing

-- | A protocol state UTxO is authentic iff its value carries exactly one of the NFT named by
-- (or derived from) its own datum, under OUR minting policy. Address + parseable datum is not
-- enough: anyone can pay a forged datum to a script address, and 2 ADA plus a hand-crafted
-- inline datum poisoned the projections for free (inherited fix #3).
authenticateStateUTxO :: GYMintingPolicyId -> GYAssetClass -> GYValue -> Bool
authenticateStateUTxO ourPolicy ac v =
  case ac of
    GYToken pid _ -> pid == ourPolicy && valueAssetClass v ac == 1
    GYLovelace -> False

pPOSIXTimeFromGYSlot :: (GYTxQueryMonad m) => GYSlot -> m POSIXTime
pPOSIXTimeFromGYSlot = (timeToPlutus <$>) . slotToBeginTime

gySlotFromPOSIXTime :: (GYTxQueryMonad m) => POSIXTime -> m GYSlot
gySlotFromPOSIXTime ptime = do
  enclosingSlotFromTime' (timeFromPlutus ptime)

-- | Convert a GY TxOutRef to a Plutus V3 TxOutRef.
txOutRefToV3Plutus :: GYTxOutRef -> V3.TxOutRef
txOutRefToV3Plutus gyRef =
  let (V1.TxOutRef (V1.TxId bs) i) = txOutRefToPlutus gyRef
   in V3.TxOutRef (V3.TxId bs) i

------------------------------------------------------------------------------------------------

-- * Mnemonic Utils

------------------------------------------------------------------------------------------------

readMnemonicFile :: FilePath -> IO GYExtendedPaymentSigningKey
readMnemonicFile path = do
  putStrLn $ yellowColorString $ "Mnemonic phrase at " <> show path
  fileExist <- doesFileExist path
  if fileExist
    then do
      content <- Data.Text.IO.readFile path
      readMnemonic content
    else do
      die $ "File not found: " <> show path

readMnemonic :: Text -> IO GYExtendedPaymentSigningKey
readMnemonic content = do
  case walletKeysToExtendedPaymentSigningKey <$> walletKeysFromMnemonic (Data.Text.words content) of
    Left err -> do
      putStrLn $ yellowColorString $ "Error reading mnemonic: " <> err
      die err
    Right key -> return key

-- | Get inline datum and value from UTxO
getInlineDatumAndValue :: GYUTxO -> Maybe (GYDatum, GYValue)
getInlineDatumAndValue utxo = case utxoOutDatum utxo of
  GYOutDatumInline datum -> Just (datum, utxoValue utxo)
  _ -> Nothing

-- | Get inline datum and value from UTxO or throw 'DatumParseError'.
getInlineDatumAndValueOrThrow :: (MonadError GYTxMonadException m) => GYUTxO -> m (GYDatum, GYValue)
getInlineDatumAndValueOrThrow utxo =
  maybe (throwError (GYApplicationException DatumParseError)) return $ getInlineDatumAndValue utxo

tnFromGYAssetClass :: (MonadError GYTxMonadException m) => GYAssetClass -> m GYTokenName
tnFromGYAssetClass (GYToken _ gyProfileRefTN) = return gyProfileRefTN
tnFromGYAssetClass _ = throwError (GYApplicationException InvalidAssetClass)

------------------------------------------------------------------------------------------------

-- * Specific Utils

------------------------------------------------------------------------------------------------

-- | Extract profile and value from UTxO
profileAndValueFromUTxO :: GYUTxO -> Maybe (CIP68Datum Onchain.OnchainProfile, Value)
profileAndValueFromUTxO profileStateUTxO = do
  (gyDatum, gyValue) <- getInlineDatumAndValue profileStateUTxO
  cip68Datum <- profileDatumFromDatum gyDatum
  let pVal = valueToPlutus gyValue
  return (cip68Datum, pVal)

-- | Convert GY datum to profile datum
profileDatumFromDatum :: GYDatum -> Maybe (CIP68Datum Onchain.OnchainProfile)
profileDatumFromDatum gyDatum = do
  let plutusDatum = datumToPlutus' gyDatum
  fromBuiltinData plutusDatum

profileFromGYOutDatum :: GYOutDatum -> Maybe (CIP68Datum Onchain.OnchainProfile)
profileFromGYOutDatum (GYOutDatumInline gyDatum) = profileDatumFromDatum gyDatum
profileFromGYOutDatum _ = Nothing

oracleParamsFromDatum :: GYDatum -> Maybe OracleParams
oracleParamsFromDatum gyDatum =
  fromBuiltinData (datumToPlutus' gyDatum)

achievementDatumFromDatum :: GYDatum -> Maybe (CIP68Datum OnchainAchievement)
achievementDatumFromDatum gyDatum =
  fromBuiltinData (datumToPlutus' gyDatum)

achievementFromGYOutDatum :: GYOutDatum -> Maybe (CIP68Datum OnchainAchievement)
achievementFromGYOutDatum (GYOutDatumInline gyDatum) = achievementDatumFromDatum gyDatum
achievementFromGYOutDatum _ = Nothing

achievementAndValueFromUTxO :: GYUTxO -> Maybe (CIP68Datum OnchainAchievement, Value)
achievementAndValueFromUTxO utxo = do
  (gyDatum, gyValue) <- getInlineDatumAndValue utxo
  datum <- achievementDatumFromDatum gyDatum
  let pVal = valueToPlutus gyValue
  return (datum, pVal)