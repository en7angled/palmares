{-# LANGUAGE NoImplicitPrelude #-}

-- | Deterministic ID generation for on-chain protocol entities.
--
-- Every deterministic token name in the protocol is derived here, and nowhere else. Two shapes cover
-- the cases the protocol has:
--
--   * 'deriveSeededId' — a one-shot name from a seed 'TxOutRef'. Unique by construction, because a
--     'TxOutRef' can only be spent once. This is what an issuance uses.
--   * 'deriveIndexedId' — a child name from a parent name plus an index, so a sequence of related
--     entities is addressable without storing each id in a datum.
--
-- Both produce 28-byte names via 'blake2b_224', which is the size CIP-68 reference/user token pairs
-- are built on. The entity-specific derivations (attestations, disputes) are thin wrappers over these
-- two and live with their payload types.
module Palmares.Onchain.Protocol.Id
  ( deriveSeededId,
    deriveIndexedId,
  )
where

import Palmares.Onchain.Utils (nameFromTxOutRef)
import PlutusLedgerApi.V1.Value (AssetClass (..))
import PlutusLedgerApi.V3 (CurrencySymbol, TokenName (TokenName), TxOutRef)
import PlutusTx.Builtins (ByteOrder (BigEndian), appendByteString, blake2b_224, integerToByteString)
import PlutusTx.Prelude (Integer)

-- | Generate a unique ID from a seed 'TxOutRef'. The seed ensures uniqueness, since each
-- 'TxOutRef' can only be spent once.
{-# INLINEABLE deriveSeededId #-}
deriveSeededId :: TxOutRef -> CurrencySymbol -> AssetClass
deriveSeededId seed cs = AssetClass (cs, TokenName (nameFromTxOutRef seed))

-- | Derive a child ID from a parent ID and an index, as @blake2b_224 (parentName <> bigEndian index)@.
-- The child's name is recomputable from the parent's datum, so it never has to be stored.
{-# INLINEABLE deriveIndexedId #-}
deriveIndexedId :: AssetClass -> Integer -> AssetClass
deriveIndexedId (AssetClass (cs, TokenName bs)) i =
  AssetClass (cs, TokenName (blake2b_224 (bs `appendByteString` integerToByteString BigEndian 0 i)))
