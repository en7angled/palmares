-- | On-chain and oracle lookups for transaction building (profiles, attestations, oracle params, dust).
module Palmares.TxBuilding.Lookups where

import Control.Monad.Except ()
import Control.Monad.Reader.Class (MonadReader, asks)
import Data.Maybe
import Data.Typeable (cast)
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types
import Palmares.DomainTypes.Transfer.Types
import GeniusYield.TxBuilder
import GeniusYield.TxBuilder.Errors ()
import GeniusYield.Types (GYTxOutRef, GYUTxO, filterUTxOs, mintingPolicyIdFromCurrencySymbol, utxoRef, utxoValue, utxosToList)
import GeniusYield.Types.Address
import GeniusYield.Types.Value
import Palmares.Onchain.CIP68 (CIP68Datum (..), deriveRefFromUserAC, userTokenPrefixBS)
import Palmares.Onchain.Protocol qualified as Onchain
import Palmares.Onchain.Protocol.Types (checkNoOpenDispute)
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import PlutusLedgerApi.V1.Value (CurrencySymbol, Value, adaSymbol, flattenValue)
import PlutusTx.Builtins (sliceByteString, lengthOfByteString)
import PlutusLedgerApi.V1.Value qualified as PlutusValue
import Palmares.TxBuilding.Context (DeployedScriptsContext (..))
import Palmares.TxBuilding.Conversions (profileDatumToProfileData)
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.TxBuilding.Utils (attestationAndValueFromUTxO, disputeAndValueFromUTxO, getInlineDatumAndValue, oracleParamsFromDatum, profileAndValueFromUTxO)
import Palmares.TxBuilding.Validators (disputesValidatorGY, oracleValidatorGY)

------------------------------------------------------------------------------------------------

-- * OnChainProfileData Lookup Functions

------------------------------------------------------------------------------------------------

-- | Return the single UTxO from a list, or throw a domain error for empty or multiple.
singleUTxOOrThrow ::
  (GYTxQueryMonad m) =>
  [GYUTxO] ->
  TxBuildingException ->
  TxBuildingException ->
  m GYUTxO
singleUTxOOrThrow utxos errEmpty errMultiple = case utxos of
  [u] -> return u
  [] -> throwError (GYApplicationException errEmpty)
  _ -> throwError (GYApplicationException errMultiple)

-- | Get UTxO by NFT asset class; throw 'NFTNotFound' if absent, 'MultipleUtxosFound' if ambiguous.
getUTxOWithNFT :: (GYTxQueryMonad m) => GYAssetClass -> m GYUTxO
getUTxOWithNFT gyAC = do
  nonAdaToken <- maybe (throwError (GYApplicationException InvalidAssetClass)) return (nonAdaTokenFromAssetClass gyAC)
  utxos <- utxosWithAsset nonAdaToken
  singleUTxOOrThrow (utxosToList utxos) NFTNotFound MultipleUtxosFound

-- | Get UTxO by NFT asset class; rethrow 'NFTNotFound' as the given domain exception.
getUTxOWithNFTOrThrow :: (GYTxQueryMonad m) => GYAssetClass -> TxBuildingException -> m GYUTxO
getUTxOWithNFTOrThrow gyAC onNotFound =
  catchError (getUTxOWithNFT gyAC) $ \e ->
    case e of
      GYApplicationException ex ->
        case cast ex :: Maybe TxBuildingException of
          Just NFTNotFound -> throwError (GYApplicationException onNotFound)
          _ -> throwError e
      _ -> throwError e

getUTxOWithTokenAtAddresses :: (GYTxQueryMonad m) => GYAssetClass -> [GYAddress] -> TxBuildingException -> m GYUTxO
getUTxOWithTokenAtAddresses nftAC addrs onNotFound = do
  utxos <- utxosAtAddresses addrs
  let utxosWithNFT = filterUTxOs (\utxo -> valueAssetPresent (utxoValue utxo) nftAC) utxos
  singleUTxOOrThrow (utxosToList utxosWithNFT) onNotFound MultipleUtxosFound

-- | Look up the single UTxO holding an NFT and parse its state datum+value.
-- Throws @onNotFound@ if the UTxO is absent, @onParseFail@ if its datum does not
-- parse — so a genuine parse failure is distinguishable from a missing UTxO (F-26).
getStateOrThrow ::
  (GYTxQueryMonad m) =>
  GYAssetClass ->
  (GYUTxO -> Maybe (a, Value)) ->
  TxBuildingException ->
  TxBuildingException ->
  m (a, Value)
getStateOrThrow gyAC parse onNotFound onParseFail = do
  utxo <- getUTxOWithNFTOrThrow gyAC onNotFound
  case parse utxo of
    Just r -> return r
    Nothing -> throwError (GYApplicationException onParseFail)

-- | Get profile state datum and value from asset class
getProfileStateDatumAndValue :: (GYTxQueryMonad m) => GYAssetClass -> m (CIP68Datum Onchain.OnchainProfile, Value)
getProfileStateDatumAndValue profileRefAC =
  getStateOrThrow profileRefAC profileAndValueFromUTxO ProfileNotFound DatumParseError




------------------------------------------------------------------------------------------------

-- * Profile Information  Lookup Functions

------------------------------------------------------------------------------------------------

getOrganizationInformation :: (GYTxQueryMonad m) => ProfileRefAC -> m OrganizationProfileInformation
getOrganizationInformation profileRefAC = do
  (profileDatum, _profileValue) <- getProfileStateDatumAndValue profileRefAC
  let ProfileData {profileDataName, profileDataDescription, profileDataImageURI} = profileDatumToProfileData profileDatum
  case Onchain.profileKind (extra profileDatum) of
    Onchain.Organization -> do
      return $
        OrganizationProfileInformation
          { organizationId = profileRefAC,
            organizationName = profileDataName,
            organizationDescription = profileDataDescription,
            organizationImageURI = profileDataImageURI
          }
    _ -> throwError (GYApplicationException WrongProfileType)

------------------------------------------------------------------------------------------------

-- * Oracle Lookup Functions

------------------------------------------------------------------------------------------------

-- | Query the oracle UTxO and parse its 'OracleParams' datum.
-- Looks up the oracle UTxO by finding the oracle NFT at the oracle validator address.
-- Returns the parsed params, the UTxO reference, and the UTxO value.
queryOracleParams ::
  (GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  m (OnchainTypes.OracleParams, GYTxOutRef, GYValue)
queryOracleParams = do
  oracleAC <- asks oracleNFTAssetClass
  oracleAddr <- scriptAddress oracleValidatorGY
  utxo <- getUTxOWithTokenAtAddresses oracleAC [oracleAddr] OracleNotFound
  case getInlineDatumAndValue utxo of
    Just (gyDatum, _) ->
      case oracleParamsFromDatum gyDatum of
        Just params -> return (params, utxoRef utxo, utxoValue utxo)
        Nothing -> throwError (GYApplicationException OracleDatumInvalid)
    Nothing -> throwError (GYApplicationException OracleNotFound)

------------------------------------------------------------------------------------------------

-- * Dust / Cleanup Lookup Functions

------------------------------------------------------------------------------------------------

-- | Find dust UTxOs at a validator address: those that contain no token
-- with the protocol's 'CurrencySymbol'. These are griefing/dust UTxOs
-- that can be cleaned up via the permissionless 'Cleanup' redeemer.
getDustUTxOs ::
  (GYTxQueryMonad m) =>
  GYAddress -> CurrencySymbol -> m [GYUTxO]
getDustUTxOs addr protocolCS = do
  allUtxos <- utxosAtAddresses [addr]
  return $ filter (not . hasProtocolToken) (utxosToList allUtxos)
  where
    hasProtocolToken utxo =
      any (\(cs, _, _) -> cs == protocolCS) $ flattenValue $ valueToPlutus $ utxoValue utxo

------------------------------------------------------------------------------------------------

-- * Attestation Lookup Functions

------------------------------------------------------------------------------------------------

-- | Get an attestation CIP68 datum and value by its NFT asset class.
getAttestationDatumAndValue :: (GYTxQueryMonad m) => GYAssetClass -> m (CIP68Datum OnchainTypes.OnchainAttestation, Value)
getAttestationDatumAndValue attestationAC =
  getStateOrThrow attestationAC attestationAndValueFromUTxO AttestationNotFound DatumParseError

-- | The thing an attestation is about must exist on chain before the attestation is built.
--
-- The off-chain half of Review Focus item 3, and it has to live off chain: the minting policy checks
-- only that the subject's asset class carries the protocol currency symbol (@Mg@), and nothing in
-- this protocol burns — so an attestation about a subject that was never minted is a record no
-- subject can ever counter-sign and nobody can ever remove. A separate error from the issuer's
-- 'ProfileNotFound', because the two are different mistakes made by different parties.
--
-- __Existence only, not kind.__ It deliberately does not require the subject to be a profile: an
-- attestation ABOUT an earlier attestation is a lineage record the spec asks for, and its subject is
-- an attestation id. Requiring a profile datum here would refuse that whole feature in order to
-- catch nothing extra — a UTxO holding the subject NFT is what makes the record resolvable, which is
-- the property at stake.
ensureSubjectProfileExists :: (GYTxQueryMonad m) => GYAssetClass -> m ()
ensureSubjectProfileExists subjectAC =
  () <$ getUTxOWithNFTOrThrow subjectAC SubjectProfileNotFound

------------------------------------------------------------------------------------------------

-- * Dispute Lookup Functions

------------------------------------------------------------------------------------------------

-- | Get a dispute CIP68 datum and value by its NFT asset class.
getDisputeDatumAndValue :: (GYTxQueryMonad m) => GYAssetClass -> m (CIP68Datum OnchainTypes.OnchainDispute, Value)
getDisputeDatumAndValue disputeAC =
  getStateOrThrow disputeAC disputeAndValueFromUTxO DisputeNotFound DatumParseError

-- | Every unresolved dispute against this attestation, read off the Disputes validator address.
--
-- __What this is for is a courtesy, not a protocol rule.__ Nothing on chain bounds the number of
-- disputes one attestation can carry; that would need an index UTxO every dispute had to contend for.
-- The deposit is what bounds the spam, since N disputes cost N deposits. 'openDisputeTX' consults
-- this so the duplicate a human would not have meant is refused with an explanation, and the read
-- layer must not present the result as a guarantee.
--
-- The open-against-target test is 'checkNoOpenDispute' applied to one dispute at a time rather than a
-- second copy of the same predicate: that function is the on-chain definition of \"open against this
-- target\" and is already pinned by tests, so there is one place the rule is written.
getOpenDisputesForAttestation ::
  (GYTxQueryMonad m) => OnchainTypes.AttestationId -> m [OnchainTypes.OnchainDispute]
getOpenDisputesForAttestation target = do
  disputesAddr <- scriptAddress disputesValidatorGY
  utxos <- utxosAtAddresses [disputesAddr]
  let disputes = [extra datum | utxo <- utxosToList utxos, Just (datum, _v) <- [disputeAndValueFromUTxO utxo]]
  return $ filter (\d -> not (checkNoOpenDispute target [d])) disputes


-- | Find profile reference NFT AssetClasses for User NFTs held at the given addresses.
-- Scans UTxO values for tokens whose Plutus token name starts with the CIP-67 user prefix,
-- then derives the corresponding reference token name.
getProfileRefACsAtAddress :: (GYTxQueryMonad m) => [GYAddress] -> m [ProfileRefAC]
getProfileRefACsAtAddress addrs = do
  utxos <- utxosAtAddresses addrs
  let allValues = map utxoValue (utxosToList utxos)
      userNFTs =
        [ (cs, tn)
          | v <- allValues,
            (cs, tn, amt) <- flattenValue (valueToPlutus v),
            amt > 0,
            cs /= adaSymbol,
            isUserTokenName tn
        ]
      refACs = mapMaybe plutusUserNFTToRefAC userNFTs
  return refACs
  where
    isUserTokenName (PlutusValue.TokenName bs) =
      lengthOfByteString bs >= 4
        && sliceByteString 0 4 bs == userTokenPrefixBS
    plutusUserNFTToRefAC (cs, tn) =
      let PlutusValue.AssetClass (refCS, refTN) = deriveRefFromUserAC (PlutusValue.AssetClass (cs, tn))
       in case (mintingPolicyIdFromCurrencySymbol refCS, tokenNameFromPlutus refTN) of
            (Right mpid, Just gyTN) -> Just (GYToken mpid gyTN)
            _ -> Nothing
