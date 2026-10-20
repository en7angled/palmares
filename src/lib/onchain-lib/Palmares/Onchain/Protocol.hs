{-# LANGUAGE NoImplicitPrelude #-}

-- | Re-exports 'Onchain.Protocol.Types', 'Onchain.Protocol.Id', 'Onchain.Protocol.Lookup',
-- and 'Onchain.Protocol.Core' so that existing @import Onchain.Protocol@
-- statements continue to work unchanged.
module Palmares.Onchain.Protocol
  ( module Onchain.Protocol.Types,
    module Onchain.Protocol.Id,
    module Onchain.Protocol.Lookup,
    module Onchain.Protocol.Core,
  )
where

import Palmares.Onchain.Protocol.Core
import Palmares.Onchain.Protocol.Id
import Palmares.Onchain.Protocol.Lookup
import Palmares.Onchain.Protocol.Types
