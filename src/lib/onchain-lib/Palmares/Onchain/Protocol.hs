{-# LANGUAGE NoImplicitPrelude #-}

-- | Re-export barrel: one import for the protocol's types and datum lookups.
--
-- @Protocol.Id@ was a third member of this barrel and is gone. It held @deriveSeededId@ and
-- @deriveIndexedId@, neither of which ever had a caller: every deterministic name in this protocol
-- is built from @Utils.nameFromTxOutRef@ wrapped by @CIP68.generateRefAndUserTN@, which is where the
-- CIP-67 prefixes are applied. Re-exporting two unused derivations here made them look like the
-- protocol's public ID surface, and the top-level @CLAUDE.md@ pointed new on-chain types at that
-- module — so the dead code was actively misdirecting, not merely idle. Removing it is hash-neutral
-- for the same reason it was dead: nothing reached it, so nothing inlined it.
module Palmares.Onchain.Protocol
  ( module Palmares.Onchain.Protocol.Types,
    module Palmares.Onchain.Protocol.Lookup,
  )
where

import Palmares.Onchain.Protocol.Lookup
import Palmares.Onchain.Protocol.Types
