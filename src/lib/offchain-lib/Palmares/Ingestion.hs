{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- | Chain event projection: maps raw on-chain UTxO datums to domain-level events.
module Palmares.Ingestion where

import Data.Maybe (isJust)
import Palmares.DomainTypes.Core.Types
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.ChainSync.KupoAtlas
import Palmares.TxBuilding.Conversions
import Palmares.TxBuilding.Utils
import Palmares.TxBuilding.Validators (achievementsValidatorHashGY, profilesValidatorHashGY)

-- | Classified domain event produced by projecting an on-chain UTxO datum.
data ChainEventProjection
  = ProfileEvent Profile
  | AchievementEvent Achievement
  | NoEvent AtlasMatch
  deriving (Show)

-- | Project an 'AtlasMatch' into a domain event by inspecting the validator address and datum.
-- Spent UTxOs are ignored (returned as 'NoEvent').
projectChainEvent :: (MonadError GYTxMonadException m) => GYNetworkId -> AtlasMatch -> m ChainEventProjection
projectChainEvent nid am@AtlasMatch {..} =
  if isJust amSpentAt
    then return $ NoEvent am
    else case amAddress of
      add | add == addressFromScriptHash nid profilesValidatorHashGY -> do
        case profileFromGYOutDatum amDatum of
          Nothing -> return $ NoEvent am
          Just onchainProfile -> do
            profile <- profileDatumToProfile onchainProfile
            return $ ProfileEvent profile
      add | add == addressFromScriptHash nid achievementsValidatorHashGY -> do
        case achievementFromGYOutDatum amDatum of
          Nothing -> return $ NoEvent am
          Just onchainAchievement -> do
            achievement <- onchainAchievementToAchievement onchainAchievement
            return $ AchievementEvent achievement
      _ -> return $ NoEvent am

--- No need to delete profile projections since the profile cannot be deleted onchain;
