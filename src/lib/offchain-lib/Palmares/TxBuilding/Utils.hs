-- | Datum parsing, GY/Plutus conversions, and small helpers for TxBuilding.
module Palmares.TxBuilding.Utils where

import Cardano.Api (Key (getVerificationKey), castVerificationKey)
import Control.Monad.Except (throwError)
import Data.Text
import Data.Text.IO qualified
import GeniusYield.TxBuilder.Class (enclosingSlotFromTime', slotToBeginTime)
import GeniusYield.Types.SlotConfig (GYSlotConfig, enclosingSlotFromTimePure, slotToBeginTimePure)
import GeniusYield.TxBuilder.Errors (GYTxMonadException (GYApplicationException))
import GeniusYield.TxBuilder.Query.Class (GYTxQueryMonad)
import GeniusYield.Types (GYAddress, GYAssetClass (..), GYDatum, GYExtendedPaymentSigningKey, GYMintingPolicyId, GYNetworkId (..), GYOutDatum (..), GYPaymentKeyHash, GYSlot, GYTokenName, slotToInteger, unsafeSlotFromInteger, GYTxOutRef, GYUTxO, GYValue, mintingPolicyIdFromCurrencySymbol, paymentKeyHash, tokenNameFromPlutus, tokenNameToPlutus, txOutRefToPlutus, utxoOutDatum, utxoValue, valueAssetClass, valueToPlutus)
import GeniusYield.Types.Address (addressFromPaymentKeyHash)
import GeniusYield.Types.Datum (datumToPlutus')
import GeniusYield.Types.Key (extendedPaymentSigningKeyToApi, paymentVerificationKeyFromApi)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import GeniusYield.Types.Time (timeFromPOSIX, timeFromPlutus, timeToPOSIX, timeToPlutus)
import GeniusYield.Types.Wallet
import Palmares.Onchain.CIP68 (CIP68Datum)
import Palmares.Onchain.Protocol qualified as Onchain
import Palmares.Onchain.Protocol.Types (OnchainAttestation, OnchainDispute, OracleParams)
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

-- | A protocol state UTxO is authentic iff its value carries exactly one of the CIP-67 __reference__
-- token its own datum names, under OUR minting policy.
--
-- Address plus a parseable datum is not enough: anyone can pay a forged datum to a script address,
-- and 2 ADA plus a hand-crafted inline datum poisoned the projections for free (inherited fix #3).
--
-- __THE REFERENCE-PREFIX CONJUNCT IS THE WHOLE SECOND HALF, and it was missing.__ This function used
-- to read @pid == ourPolicy && valueAssetClass v ac == 1@ — which is 'hasCurrencySymbol' with a
-- quantity check bolted on, and a profile's own USER token satisfies it. User tokens are supposed to
-- reach a wallet; that is what CIP-68 is for. So the attack was:
--
--   1. mint a profile, permissionlessly, and keep its user token @U@;
--   2. pay a SCRIPTLESS output to the Attestations validator's address carrying 1 × @U@, min-ADA,
--      and a hand-written @OnchainAttestation@ whose @attestationId@ is @U@, whose subject is the
--      victim's real profile id, whose issuer is any reputable profile's real id, and whose
--      @attestationIsAccepted@ is @True@.
--
-- No validator runs — paying TO a script address needs no witness. Kupo indexes every asset name
-- under the policy, the datum parses, and this was the only gate. The registry then served a forged,
-- ACCEPTED attestation from a reputable issuer on the victim's own "attestations about me" query,
-- for about 1.3 ADA, with no cooperation from anybody, and nothing in this protocol burns so it
-- could never be removed. The same output shape with a 'CredentialClaim' datum forges a BINDING of
-- the victim's governance credential to the attacker's profile with no @Mc3@ proof — which until
-- ADR 0003 was the same attack against a profile's own credential field and @Mp3@.
--
-- __Why the prefix closes it completely.__ A reference token provably cannot reach a wallet:
-- @Mp5@/@Mk@/@Md5@ force the single minted ref NFT into a script output carrying the datum the
-- policy itself computed, @P5@/@A1@/@D2@ each re-lock at least that value at the same address, and
-- every @Cleanup@ refuses a UTxO whose value holds the NFT its datum names. An attacker therefore
-- never holds one to park. A token of a FOREIGN policy named with the ref prefix fails the first
-- conjunct, so both halves are needed and neither is redundant.
--
-- __It is the same predicate @Mg@ and @Md4@ were upgraded over__, on the same day, for the same
-- reason — a user token makes 'deriveUserFromRefTN' the identity. Those two guard the ids the mint
-- path READS; this one guards the id the protocol TRUSTS AS STATE, which is the site where a forged
-- datum becomes a record. It was left on the old version.
--
-- __It takes the kind's OWN name predicate, exactly as 'Palmares.Onchain.Utils.isUnbackedDatum'
-- does, and that is a fix and not a generalisation.__ This hardcoded
-- 'Palmares.Onchain.CIP68.isRefTokenName' — CIP-67 label 100 — while `OC-05` had moved attestations
-- to label 1 and disputes to label 2. So the gate was @False@ for every id the minting policy can
-- produce for those two kinds, and 'Palmares.Ingestion.projectChainEvent' returned @NoEvent@ for
-- every genuine attestation and every genuine dispute: the whole attestation read surface was dead,
-- silently, while profiles projected normally. Measured on preprod 2026-10-24, on the first
-- end-to-end run there has ever been (F1 check 11): six raw matches, two profile projections, one
-- unspent attestation on chain at the attestations address, @GET \/attestations@ → @total: 0@.
--
-- The paragraph above says this predicate "was left on the old version" — it was describing the
-- on-chain twin's upgrade. The off-chain one was left on the old version too, and nothing noticed,
-- because the only tests that fed it an attestation id gave that id the PROFILE label.
authenticateStateUTxO :: (TokenName -> Bool) -> GYMintingPolicyId -> GYAssetClass -> GYValue -> Bool
authenticateStateUTxO isOwnKindName ourPolicy ac v =
  case ac of
    GYToken pid tn ->
      pid == ourPolicy
        && isOwnKindName (tokenNameToPlutus tn)
        && valueAssetClass v ac == 1
    GYLovelace -> False

-- | Chain time for a stored @created_at_slot@. Pure, so a handler maps a whole page with one
-- slot config instead of calling the monadic 'slotToBeginTime' once per row.
slotToUTC :: GYSlotConfig -> Integer -> UTCTime
slotToUTC cfg = posixSecondsToUTCTime . timeToPOSIX . slotToBeginTimePure cfg . unsafeSlotFromInteger

-- | A @since@ query parameter as a slot, so the comparison happens on the indexed column.
-- A time before the system start clamps to slot 0 — i.e. "no lower bound", which is what
-- @since@ means.
utcToSlot :: GYSlotConfig -> UTCTime -> Integer
utcToSlot cfg =
  maybe 0 slotToInteger . enclosingSlotFromTimePure cfg . timeFromPOSIX . utcTimeToPOSIXSeconds

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

attestationDatumFromDatum :: GYDatum -> Maybe (CIP68Datum OnchainAttestation)
attestationDatumFromDatum gyDatum =
  fromBuiltinData (datumToPlutus' gyDatum)

attestationFromGYOutDatum :: GYOutDatum -> Maybe (CIP68Datum OnchainAttestation)
attestationFromGYOutDatum (GYOutDatumInline gyDatum) = attestationDatumFromDatum gyDatum
attestationFromGYOutDatum _ = Nothing

attestationAndValueFromUTxO :: GYUTxO -> Maybe (CIP68Datum OnchainAttestation, Value)
attestationAndValueFromUTxO utxo = do
  (gyDatum, gyValue) <- getInlineDatumAndValue utxo
  datum <- attestationDatumFromDatum gyDatum
  let pVal = valueToPlutus gyValue
  return (datum, pVal)

disputeDatumFromDatum :: GYDatum -> Maybe (CIP68Datum OnchainDispute)
disputeDatumFromDatum gyDatum =
  fromBuiltinData (datumToPlutus' gyDatum)

-- | A dispute datum and value from a UTxO, or 'Nothing' when the datum is absent or is not a dispute.
--
-- 'Nothing' is also how a dust UTxO at the Disputes validator address is skipped when scanning the
-- address for a target's disputes, which is the same thing the @Cleanup@ redeemer treats as sweepable.
disputeAndValueFromUTxO :: GYUTxO -> Maybe (CIP68Datum OnchainDispute, Value)
disputeAndValueFromUTxO utxo = do
  (gyDatum, gyValue) <- getInlineDatumAndValue utxo
  datum <- disputeDatumFromDatum gyDatum
  let pVal = valueToPlutus gyValue
  return (datum, pVal)