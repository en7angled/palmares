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
import GeniusYield.Types (GYOutDatum (..), GYTxOutRef, GYUTxO, filterUTxOs, mintingPolicyIdFromCurrencySymbol, utxoOutDatum, utxoRef, utxoValue, utxosToList)
import GeniusYield.Types.Address
import GeniusYield.Types.Value
import Palmares.Onchain.CIP68 (CIP68Datum (..), deriveRefFromUserAC, userTokenPrefixBS)
import Palmares.Onchain.Protocol qualified as Onchain
import Palmares.Onchain.Protocol.Types (checkNoOpenDispute)
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import PlutusLedgerApi.V1.Value (Value, adaSymbol, flattenValue)
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

-- | The UTxOs at one state validator address that that validator's @Cleanup@ arm will let anyone
-- spend — dust wearing a datum, rather than protocol state.
--
-- __This is 'Palmares.Onchain.Utils.isUnbackedDatum' off chain, and it has to be the same predicate
-- in both directions.__ It used to select on \"the value holds no token of the protocol's policy\",
-- which agrees with no validator and disagrees with all three:
--
--   * __False positives, and they BRICK the sweep.__ 'Palmares.TxBuilding.Operations.cleanupDustTX'
--     builds ONE all-or-nothing transaction over all three addresses, so a single UTxO in this list
--     that the validator then refuses fails the whole sweep — for ever, since nothing in this
--     protocol burns and the refusal is deterministic. Planting one cost about 1.3 ADA: mint a token
--     under your OWN policy whose name starts with a state label (@0x00001070@ for an attestation),
--     and pay it to that address with a hand-written @CIP68Datum OnchainAttestation@ naming it as
--     @attestationId@. Foreign policy, so the old filter saw no protocol token and offered it;
--     the datum parses, the label matches and the value holds exactly 1 of the named token, so @A4@
--     refused it and every later sweep died with it. Permissionless griefing of a permissionless
--     redeemer.
--   * __False negatives, so real dust accumulated.__ Any protocol token other than the state NFT the
--     datum names made the old filter skip the UTxO, and the validators sweep exactly that: a
--     profile's USER token mis-sent to a state address, with or without a datum, is sweepable
--     ('Palmares.Onchain.Utils.isUnbackedDatum' documents the case), and nothing offered it.
--
-- __Deliberately NOT policy-scoped__, which is where this differs from its read-layer twin
-- 'Palmares.TxBuilding.Utils.authenticateStateUTxO'. That one is the same shape — it takes the
-- kind's own CIP-67 name predicate for the reason @OC-05@ gave both of them — and it adds
-- @pid == ourPolicy@, because the read layer knows the protocol's policy and must not serve a
-- foreign token as state. The three state validators are unparameterised on purpose and cannot know
-- it, so adding that conjunct here would re-create the first bullet exactly: a ref-prefixed token of
-- the attacker's own policy would read as \"not authentic, therefore dust\" off chain and \"backed,
-- therefore state\" on chain. A sweep selector must mirror the validator, not the registry.
--
-- __A datum HASH is skipped, and that is the one place this is knowingly weaker than the arm.__
-- 'Palmares.TxBuilding.Skeletons.txMustSpendUTxOFromRefScript' witnesses the spend with the inline
-- datum or with 'Nothing', and a Conway script input whose output carries a datum hash must supply
-- the preimage — which an address scan does not have. Offering such a UTxO therefore produces a
-- transaction the ledger rejects before any validator runs: the same permanent brick as the first
-- bullet, through a second door at the same price. The arm would sweep it for anyone who knows the
-- preimage; this list is what the builder can actually spend.
getDustUTxOs ::
  (GYTxQueryMonad m) =>
  -- | The address's own CIP-67 label predicate: 'Palmares.Onchain.CIP68.isRefTokenName',
  -- @isAttestationTokenName@ or @isDisputeTokenName@. Must be the one the validator at @addr@ passes
  -- to 'Palmares.Onchain.Utils.isUnbackedDatum' — profiles wear label 100, attestations label 1 and
  -- disputes label 2, so a shared one would mean \"every attestation and every dispute is dust\".
  (PlutusValue.TokenName -> Bool) ->
  -- | The address's own datum parser: 'Palmares.TxBuilding.Utils.profileAndValueFromUTxO',
  -- @attestationAndValueFromUTxO@ or @disputeAndValueFromUTxO@. 'Nothing' is the validator's two
  -- sweepable arms at once — no datum and a datum that is not this kind's.
  (GYUTxO -> Maybe (CIP68Datum a, Value)) ->
  -- | The NFT that kind's datum names: @profileId@, @attestationId@ or @disputeId@. All three are an
  -- 'PlutusValue.AssetClass', so a mix-up type-checks — the reason each caller names it beside its
  -- own validator and redeemer.
  (a -> PlutusValue.AssetClass) ->
  GYAddress ->
  m [GYUTxO]
getDustUTxOs isOwnKindName parseStateDatum stateIdOf addr = do
  allUtxos <- utxosAtAddresses [addr]
  return $ filter isSweepable (utxosToList allUtxos)
  where
    isSweepable utxo = case utxoOutDatum utxo of
      GYOutDatumHash _ -> False
      _ -> case parseStateDatum utxo of
        -- The arm's own first two cases: @Nothing -> True@ for an absent datum, and again for one
        -- that is not this kind's state. Neither reaches a trace code — @P0@\/@A0@\/@D0@ are the
        -- no-datum codes on the OTHER redeemers, and @Cleanup@ simply allows the spend.
        Nothing -> True
        -- And the last line is 'Palmares.Onchain.Utils.isUnbackedDatum' itself, on the value the
        -- parse already handed back, which is this UTxO's own — the same @txOutValue ownInput@ the
        -- arm reads.
        Just (parkedDatum, parkedValue) ->
          let stateNFT@(PlutusValue.AssetClass (_, tn)) = stateIdOf (extra parkedDatum)
           in not (isOwnKindName tn) || PlutusValue.assetClassValueOf parkedValue stateNFT == 0

------------------------------------------------------------------------------------------------

-- * Attestation Lookup Functions

------------------------------------------------------------------------------------------------

-- | Get an attestation CIP68 datum and value by its NFT asset class.
getAttestationDatumAndValue :: (GYTxQueryMonad m) => GYAssetClass -> m (CIP68Datum OnchainTypes.OnchainAttestation, Value)
getAttestationDatumAndValue attestationAC =
  getStateOrThrow attestationAC attestationAndValueFromUTxO AttestationNotFound DatumParseError

-- | The thing an attestation is about must exist on chain before the attestation is built.
--
-- The off-chain half of Review Focus item 3. Nothing in this protocol burns, so an attestation about
-- a subject that was never minted is a record no subject can ever counter-sign and nobody can ever
-- remove. A separate error from the issuer's 'ProfileNotFound', because the two are different
-- mistakes made by different parties.
--
-- __EXISTENCE ONLY, AND NOW THAT IS THE WHOLE JOB__ — OC-05 moved the kind check on chain. @Mg@ used
-- to accept any reference-prefixed token of this policy, so this function was the only thing standing
-- between an issuer and a record about an attestation, a dispute, or a name nobody minted; it was a
-- courtesy, and a bypassable one, since a client that builds its own transaction never calls it. @Mg@
-- now requires a PROFILE id on both sides, by CIP-67 label, so the kind is the chain's business and
-- existence is this function's.
--
-- __The paragraph that used to end here defended LINEAGE__ — an attestation about an earlier
-- attestation — as a feature this check must not refuse. The owner dropped the feature on 2026-10-24,
-- and the honest summary is that it never worked: @A5@ asks the subject to spend the user NFT derived
-- from its id, and @handleNewAttestation@ mints no user token, so a lineage record was pending for
-- ever and presented as "pending" to a subject that could not act. Defending it cost a real check.
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
