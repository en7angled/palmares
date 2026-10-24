{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use &&" #-}

-- | CIP-68 Datum Metadata Standard implementation.
-- Provides datum types, metadata field handling, and CIP-67 token name
-- derivation for reference and user NFTs.
--
-- Two exports are gone and are worth naming so they are not written again. @updateCIP68DatumImage@
-- set the @image@ key alone; the only datum update this protocol has is @UpdateProfile@, which
-- replaces all three fields through 'updateCIP68DatumMetadata', so a single-field variant had no
-- caller. @validateImageURI@ checked @lengthOfByteString uri <= maxImageURILength@ — the SAME
-- comparison 'validateMetadataFields' already makes inline on @metadataImageURI@, so it enforced
-- nothing that was not enforced, and a reader finding two statements of one bound has to work out
-- which is live. Both were @INLINEABLE@ and unreached, so removing them cannot move a script hash.
module Palmares.Onchain.CIP68
  ( -- * Types
    CIP68Datum (..),
    MetadataFields (..),
    ImageURI,
    Metadata,
    metadataVersion,

    -- * Datum Construction and Access
    mkCIP68Datum,
    getMetadataFields,
    updateCIP68DatumMetadata,

    -- * Validation
    validateMetadataFields,
    validateOtherMetadata,
    maxOtherMetadataEntries,
    isRefTokenName,
    isProtocolRefToken,

    -- * CIP-67 Token Name Derivation
    generateRefAndUserTN,
    generateAttestationTN,
    generateDisputeTN,
    isAttestationTokenName,
    isDisputeTokenName,
    isProfileId,
    isAttestationId,
    attestationTokenPrefixBS,
    disputeTokenPrefixBS,
    deriveUserFromRefAC,
    deriveUserFromRefTN,
    deriveRefFromUserAC,
    deriveRefFromUserTN,
    userTokenPrefixBS,
  )
where

import GHC.Generics (Generic)
import PlutusLedgerApi.V1.Value
import PlutusTx
import PlutusTx.AssocMap qualified
import PlutusTx.Blueprint
import PlutusTx.Builtins
import PlutusTx.Prelude
import Prelude qualified

type ImageURI = BuiltinByteString

type Metadata = PlutusTx.AssocMap.Map BuiltinByteString BuiltinByteString

{-# INLINEABLE metadataVersion #-}
metadataVersion :: Integer
metadataVersion = 1

-- | The datum datatype which should be locked with the batch ref NFT.
-- | This datatype is following the CIP-68 Datum Metadata Standard.
data CIP68Datum plutusData = CIP68Datum
  { -- | Map k v (where k are UTF-8 encoded @BuiltinByteString@s)
    metadata :: Metadata,
    -- | Version of CIP-68 Datum Metadata Standard.
    version :: Integer,
    -- | Plutus data
    extra :: plutusData
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''CIP68Datum [('CIP68Datum, 0)]

data MetadataFields
  = Metadata222
  { metadataName :: BuiltinByteString,
    metadataDescription :: BuiltinByteString,
    metadataImageURI :: BuiltinByteString
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''MetadataFields [('Metadata222, 0)]

-- | Maximum allowed sizes for metadata fields (in bytes)
{-# INLINEABLE maxNameLength #-}
maxNameLength :: Integer
maxNameLength = 128

{-# INLINEABLE maxDescriptionLength #-}
maxDescriptionLength :: Integer
maxDescriptionLength = 1024

{-# INLINEABLE maxImageURILength #-}
maxImageURILength :: Integer
maxImageURILength = 256

-- | Validate metadata field sizes to prevent oversized datums
{-# INLINEABLE validateMetadataFields #-}
validateMetadataFields :: MetadataFields -> Bool
validateMetadataFields Metadata222 {..} =
  (lengthOfByteString metadataName <= maxNameLength) -- Name too long (max 128 bytes)
    && (lengthOfByteString metadataDescription <= maxDescriptionLength) -- Description too long (max 1024 bytes)
    && (lengthOfByteString metadataImageURI <= maxImageURILength) -- Image URI too long (max 256 bytes)

-- | Bounds for the caller-supplied half of the metadata map.
--
-- 'otherMetadata' is a CIP-68 extension point and it went into the permanent datum unbounded and
-- unchecked, which is two problems rather than one.
--
-- __Unbounded.__ The issuer pays the min-ADA for a bloated attestation, which looks like self-harm
-- until you read the accept path: @A1@ re-locks @ownValue@, so the SUBJECT is the one who has to
-- spend and relock that UTxO to accept. A big enough datum makes accepting an attestation about you
-- expensive, and past the datum limit, impossible. The attestation cannot be removed either, because
-- nothing in this protocol burns. So the griefing lands on the subject, not the issuer.
--
-- __Unchecked for duplicates.__ 'mkCIP68Datum' builds the map with @AssocMap.unsafeFromList@ and a
-- comment saying it is safe because the keys are unique. That is true of the three literals and says
-- nothing about the list appended after them. Duplicate keys break the precondition, and then
-- @AssocMap.lookup@ is whichever entry comes first while an off-chain decoder is free to disagree —
-- so the datum means two different things depending on who reads it. Collisions with the three
-- reserved keys are the worst version, since they let @otherMetadata@ shadow @name@.
-- 'Palmares.TxBuilding.Operations' already refuses those off chain
-- (@AttestationOtherMetadataReservedKeys@); this is the half a hand-built transaction cannot skip.
{-# INLINEABLE maxOtherMetadataEntries #-}
maxOtherMetadataEntries :: Integer
maxOtherMetadataEntries = 16

{-# INLINEABLE maxOtherMetadataKeyLength #-}
maxOtherMetadataKeyLength :: Integer
maxOtherMetadataKeyLength = 64

{-# INLINEABLE maxOtherMetadataValueLength #-}
maxOtherMetadataValueLength :: Integer
maxOtherMetadataValueLength = 256

-- | Validate the caller-supplied metadata entries: count, sizes, and key uniqueness.
--
-- __The count is checked FIRST and that ordering is load-bearing.__ The duplicate-key check is
-- quadratic, and a quadratic scan over a list the attacker sizes is a budget-exhaustion vector of
-- its own. Sixteen caller entries, each compared against the three reserved keys and against every
-- entry after it, is @3*16 + C(16,2)@ = at most 168 key comparisons. Bounding the count before
-- scanning turns an unbounded cost into a constant one.
--
-- That figure has been wrong twice and both ways are instructive. It said 120, which forgot the
-- reserved keys entirely. It then said 171 — @C(19,2)@ — which was right while the three reserved
-- keys were PREPENDED to the key list and every pair in the combined list was compared. They are
-- compared per entry now, which drops the three comparisons between the literals themselves.
{-# INLINEABLE validateOtherMetadata #-}
validateOtherMetadata :: [(BuiltinByteString, BuiltinByteString)] -> Bool
validateOtherMetadata entries =
  countAtMost maxOtherMetadataEntries entries && entriesAreWellFormed entries
  where
    -- `length` would walk the whole list before comparing, which is the cost this is here to bound.
    -- Still FIRST and still its own traversal, which is the part not to "optimise": folding the
    -- count into the walk below would let `keyElem` scan the whole tail once per element, so an
    -- attacker-sized 10,000-entry list would be walked sixteen times before the count refused it.
    countAtMost n xs = case xs of
      [] -> True
      (_ : rest) -> n > 0 && countAtMost (n - 1) rest

    -- ONE traversal for the sizes, the reserved keys and the duplicates. This was four separate
    -- list functions — `all`, `map`, `<>` and `keysAreUnique`, whose `elem` is `any . (==)` and so
    -- a fifth — and PLUTUSTX CANNOT SHARE A RECURSION: each is its own fixpoint in the compiled
    -- policy, at a measured ~45 bytes apiece. Three here against six before, same verdict on every
    -- input.
    --
    -- The three keys 'mkCIP68Datum' writes itself are compared per entry rather than prepended to
    -- the key list. Prepending let one `elem` catch a reserved collision and a caller-side
    -- duplicate with the same comparison, at the price of building the list; the three literals are
    -- pairwise distinct, so comparing every caller key against all three is the same test minus
    -- three conjuncts that were constantly true.
    entriesAreWellFormed xs = case xs of
      [] -> True
      ((k, v) : rest) ->
        lengthOfByteString k <= maxOtherMetadataKeyLength
          && lengthOfByteString v <= maxOtherMetadataValueLength
          && k /= encodeUtf8 "name"
          && k /= encodeUtf8 "description"
          && k /= encodeUtf8 "image"
          && not (keyElem k rest)
          && entriesAreWellFormed rest

    keyElem k xs = case xs of
      [] -> False
      ((k', _) : rest) -> k == k' || keyElem k rest

-- | Is this token name a CIP-67 __reference__ token name?
--
-- __Why a profile id has to be checked for this and not only for its currency symbol.__ A
-- 'ProfileId' is the reference token's 'AssetClass', and the mint handlers used to accept any asset
-- class of this protocol's currency symbol. Name a profile's __user__ token instead and the
-- derivation becomes the identity: @deriveUserFromRefTN@ replaces the first four bytes with the user
-- prefix, so for a name that already starts with the user prefix it returns the name unchanged.
--
-- That makes @Mf@ and @A5@ satisfiable by the profile's real owner — they hold that user token — so
-- the attestation is issued and accepted by exactly the right people while
-- @attestation_projection.subject_profile_id@ records an id that no @profile_projection@ row has.
-- The record is accepted on chain and detached from its subject in the read layer, which is a
-- deception rather than a loss: "I accepted it" is true on chain and the registry never shows it.
--
-- Four bytes of comparison on a mint path, against an effect the read layer cannot repair. The
-- three reserved-prefix bytes of CIP-67 are not checked separately; the whole four-byte prefix is
-- the test.
{-# INLINEABLE isRefTokenName #-}
isRefTokenName :: TokenName -> Bool
isRefTokenName (TokenName bs) = sliceByteString 0 4 bs == refTokenPrefixBS

-- | Is this asset class a protocol REFERENCE token: right policy, right CIP-67 prefix?
--
-- The pair of checks a protocol id has to pass, kept together because passing only the first was
-- the finding. 'isRefTokenName' above says what naming a user token instead buys an attacker.
{-# INLINEABLE isProtocolRefToken #-}
isProtocolRefToken :: AssetClass -> CurrencySymbol -> Bool
isProtocolRefToken (AssetClass (cs, tn)) cs' = cs == cs' && isRefTokenName tn

-------------------------------------------------------------------------------

-- * Typed ids — one CIP-67 label per kind

-------------------------------------------------------------------------------

-- | Is this an ATTESTATION reference token name? CIP-67 private-use label 1.
--
-- __Why a second label at all, and why ids were untyped before — @OC-05@.__ Every id in this protocol
-- was @label 100 ‖ blake2b_224(seed)@ under one policy, so @Mg@ and @Md4@ could only ask "is this a
-- reference-prefixed token of this policy". Three classes of permanent garbage followed from that:
--
--   * @subject@ could be an attestation id, or a name never minted at all. The record mints, can
--     never be accepted — @A5@ wants a user token that @handleNewAttestation@ does not mint — and can
--     never be removed, because nothing in this protocol burns. The off-chain
--     @ensureSubjectProfileExists@ is a courtesy, not a gate.
--   * @target@ on a dispute could be a profile, another dispute, or a name never minted, and the
--     projection column @targetAttestationId@ would then point at a non-attestation.
--   * Neither is a forgery. Both are clutter a four-byte check prevents.
--
-- __Why a LABEL and not a byte in the name.__ A token name is at most 32 bytes and an id is already
-- @4 + 28@ — exactly 32. There is no room for a discriminator without shortening the hash, but the
-- four bytes already spent on a label can carry the kind for free.
--
-- __Why private use and not a new registered label.__ CIP-67 reserves labels 0-15 for private use,
-- which is the spec's own answer for a protocol that needs its own classes; and the policy id already
-- scopes every check here ('isProtocolRefToken' compares the currency symbol), so a private label
-- under our own policy is unambiguous. Profiles keep 100/222 because a profile genuinely IS a CIP-68
-- pair — it has a user token and a wallet should see it as one. An attestation and a dispute have no
-- user token, so CIP-68 pairing is meaningless for them and squatting its labels would say something
-- false about them to every wallet that reads labels.
{-# INLINEABLE isAttestationTokenName #-}
isAttestationTokenName :: TokenName -> Bool
isAttestationTokenName (TokenName bs) = sliceByteString 0 4 bs == attestationTokenPrefixBS

-- | Is this a DISPUTE reference token name? CIP-67 private-use label 2.
{-# INLINEABLE isDisputeTokenName #-}
isDisputeTokenName :: TokenName -> Bool
isDisputeTokenName (TokenName bs) = sliceByteString 0 4 bs == disputeTokenPrefixBS

-- | Right policy AND a profile id: the typed replacement for 'isProtocolRefToken' wherever the thing
-- being named must be a PROFILE.
{-# INLINEABLE isProfileId #-}
isProfileId :: AssetClass -> CurrencySymbol -> Bool
isProfileId (AssetClass (cs, tn)) cs' = cs == cs' && isRefTokenName tn

-- | Right policy AND an attestation id.
{-# INLINEABLE isAttestationId #-}
isAttestationId :: AssetClass -> CurrencySymbol -> Bool
isAttestationId (AssetClass (cs, tn)) cs' = cs == cs' && isAttestationTokenName tn

-- @isDisputeId@ — \"right policy AND a dispute id\" — was the third member of this trio and is gone.
-- It had no caller, and the asymmetry is a fact about the protocol rather than an oversight: @Mg@ asks
-- 'isProfileId' of an attestation's subject and issuer, and @Md4@ asks 'isAttestationId' of a
-- dispute's target and 'isProfileId' of its opener, so an id of the DISPUTE class is never named by
-- any redeemer field anywhere. Nothing points at a dispute; a dispute points at things.
--
-- 'isDisputeTokenName' stays, and it is the half that is actually load-bearing: @D8@ passes it to
-- 'Palmares.Onchain.Utils.isUnbackedDatum' as the Disputes Validator's own kind predicate, and
-- @Ingestion@ passes it to the read layer's authenticator. The currency-symbol conjunct is the part
-- those two cannot use — the three state validators are unparameterised on purpose, so they cannot
-- know the policy that minted a token.
--
-- Hash-neutral for the reason it was dead: @INLINEABLE@ makes an unfolding available to the PlutusTx
-- plugin, it does not make the plugin take it, and no @compile@ splice's call graph reached this
-- binding. The day a redeemer does name a dispute id, this is three lines to write back — and
-- writing it back is cheaper than leaving a predicate exported that documents a rule nothing applies.

-- All UTF-8 encoded keys and values need to be converted into their respective byte's representation when creating the datum on-chain.
{-# INLINEABLE mkCIP68Datum #-}
mkCIP68Datum :: a -> MetadataFields -> [(BuiltinByteString, BuiltinByteString)] -> CIP68Datum a
mkCIP68Datum extraData Metadata222 {..} otherMetadataEncoded =
  CIP68Datum
    { metadata =
        PlutusTx.AssocMap.unsafeFromList -- Safe because keys are unique
          ( [ (encodeUtf8 "name", metadataName),
              (encodeUtf8 "description", metadataDescription),
              (encodeUtf8 "image", metadataImageURI)
            ]
              <> otherMetadataEncoded
          ),
      version = metadataVersion,
      extra = extraData
    }

{-# INLINEABLE getMetadataFields #-}
getMetadataFields :: CIP68Datum a -> MetadataFields
getMetadataFields (CIP68Datum metadata _ _) =
  Metadata222
    { metadataName = lookupMetadata "name",
      metadataDescription = lookupMetadata "description",
      metadataImageURI = lookupMetadata "image"
    }
  where
    lookupMetadata label = fromMaybe @BuiltinByteString "" $ PlutusTx.AssocMap.lookup (encodeUtf8 label) metadata

{-# INLINEABLE updateCIP68DatumMetadata #-}
updateCIP68DatumMetadata :: MetadataFields -> CIP68Datum a -> CIP68Datum a
updateCIP68DatumMetadata Metadata222 {..} oldDatum =
  let m0 = metadata oldDatum
      m1 = PlutusTx.AssocMap.insert (encodeUtf8 "description") metadataDescription m0
      m2 = PlutusTx.AssocMap.insert (encodeUtf8 "image") metadataImageURI m1
   in oldDatum {metadata = m2}

{-# INLINEABLE refTokenPrefixBS #-}
refTokenPrefixBS :: BuiltinByteString
refTokenPrefixBS = integerToByteString BigEndian 4 (0x000643b0 :: Integer) -- 4 bytes for the prefix according to CIP-67

{-# INLINEABLE userTokenPrefixBS #-}
userTokenPrefixBS :: BuiltinByteString
userTokenPrefixBS = integerToByteString BigEndian 4 (0x000de140 :: Integer) -- 4 bytes for the prefix according to CIP-67

-- | CIP-67 __private-use label 1__, the attestation class. @0x00001070@: brackets, @0x0001@, CRC-8
-- @0x07@. Computed with the spec's own algorithm and checked by reproducing all four registered
-- CIP-68 labels (100, 222, 333, 444) with the same encoder before trusting it on a new one — a wrong
-- checksum is a label every CIP-67 reader rejects, and it would be frozen into every id.
{-# INLINEABLE attestationTokenPrefixBS #-}
attestationTokenPrefixBS :: BuiltinByteString
attestationTokenPrefixBS = integerToByteString BigEndian 4 (0x00001070 :: Integer) -- CIP-67 label 1 (private use)

-- | CIP-67 __private-use label 2__, the dispute class. @0x000020e0@: brackets, @0x0002@, CRC-8 @0x0e@.
{-# INLINEABLE disputeTokenPrefixBS #-}
disputeTokenPrefixBS :: BuiltinByteString
disputeTokenPrefixBS = integerToByteString BigEndian 4 (0x000020e0 :: Integer) -- CIP-67 label 2 (private use)

{-# INLINEABLE generateRefAndUserTN #-}
generateRefAndUserTN :: BuiltinByteString -> (TokenName, TokenName)
generateRefAndUserTN bs = (TokenName (refTokenPrefixBS <> bs), TokenName (userTokenPrefixBS <> bs))

-- | The single token an attestation is: label 1 over the same name body, and NO user token.
--
-- An attestation has no owner that acts on its behalf — acceptance is the subject spending their
-- PROFILE's user token (@A5@), not the attestation's — so there is nothing for a second token to do.
-- That is also why the label is a private one rather than CIP-68's 100: a lone 100 would tell every
-- wallet to go looking for a 222 that does not exist.
{-# INLINEABLE generateAttestationTN #-}
generateAttestationTN :: BuiltinByteString -> TokenName
generateAttestationTN bs = TokenName (attestationTokenPrefixBS <> bs)

-- | The single token a dispute is: label 2 over the same name body, and no user token, for the same
-- reason. A dispute's authority is its opener's profile, recorded in its datum.
{-# INLINEABLE generateDisputeTN #-}
generateDisputeTN :: BuiltinByteString -> TokenName
generateDisputeTN bs = TokenName (disputeTokenPrefixBS <> bs)

{-# INLINEABLE deriveUserFromRefTN #-}
deriveUserFromRefTN :: TokenName -> TokenName
deriveUserFromRefTN (TokenName bs) = TokenName (userTokenPrefixBS <> sliceByteString 4 (lengthOfByteString bs) bs)

{-# INLINEABLE deriveUserFromRefAC #-}
deriveUserFromRefAC :: AssetClass -> AssetClass
deriveUserFromRefAC (AssetClass (cs, tn)) = AssetClass (cs, deriveUserFromRefTN tn)

{-# INLINEABLE deriveRefFromUserTN #-}
deriveRefFromUserTN :: TokenName -> TokenName
deriveRefFromUserTN (TokenName bs) = TokenName (refTokenPrefixBS <> sliceByteString 4 (lengthOfByteString bs - 4) bs)

{-# INLINEABLE deriveRefFromUserAC #-}
deriveRefFromUserAC :: AssetClass -> AssetClass
deriveRefFromUserAC (AssetClass (cs, tn)) = AssetClass (cs, deriveRefFromUserTN tn)
