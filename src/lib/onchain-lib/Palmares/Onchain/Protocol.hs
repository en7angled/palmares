{-# LANGUAGE NoImplicitPrelude #-}

-- | Re-export barrel: one import for the protocol's types, ID derivations and datum lookups.
module Palmares.Onchain.Protocol
  ( module Palmares.Onchain.Protocol.Types,
    module Palmares.Onchain.Protocol.Id,
    module Palmares.Onchain.Protocol.Lookup,
  )
where

import Palmares.Onchain.Protocol.Id
import Palmares.Onchain.Protocol.Lookup
import Palmares.Onchain.Protocol.Types
