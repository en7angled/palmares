module Test.Helpers
  ( assert,
    queryOracle,
    failedWithTrace,
  )
where

import Control.Monad.Reader (runReaderT)
import Data.List.Extra (breakOn, isInfixOf)
import GeniusYield.TxBuilder (GYTxMonadException)
import GeniusYield.TxBuilder.Query.Class (GYTxQueryMonad)
import Palmares.Onchain.Protocol.Types (OracleParams (..))
import Palmares.TxBuilding.Context (DeployedScriptsContext)
import Palmares.TxBuilding.Lookups (queryOracleParams)

-- | Assert a boolean in the test monad; calls 'error' if False.
assert :: (GYTxQueryMonad m) => Bool -> m ()
assert True = return ()
assert False = error "Assertion failed"

-- | Query oracle params from the deployed scripts context.
queryOracle :: (GYTxQueryMonad m) => DeployedScriptsContext -> m OracleParams
queryOracle ctx = do
  (params, _, _) <- runReaderT queryOracleParams ctx
  return params

-- | A predicate for 'GeniusYield.Test.Clb.mustFailWith': the transaction was refused __by this
-- specific on-chain check__.
--
-- @mustFail@ on its own passes when a transaction fails for any reason at all — a balancer error, a
-- missing signatory, a script that was never reached. That is how the inherited suite shipped a
-- "non-admin oracle update fails" case that died at the required-signer layer and would have kept
-- passing with the validator's admin check deleted. Naming the code is what turns a negative test
-- from "something went wrong" into "this guard did it".
--
-- __This only works because the validators are compiled with traces intact__ (the
-- @preserve-logging@ flag in @palmares.cabal@, on by default). Under @remove-trace@ the codes are
-- stripped before the script runs, every execution log is empty, and every call here returns
-- 'False' — so a build that strips traces fails these tests loudly rather than passing them
-- vacuously, which is the right way round.
--
-- Matched against the execution-log section of the rendered exception rather than the whole thing:
-- the full render embeds the script's own bytes, where a two-character code appears by coincidence.
failedWithTrace :: String -> GYTxMonadException -> Bool
failedWithTrace code e = case breakOn marker (show e) of
  (_, "") -> False
  (_, logs) -> show code `isInfixOf` take 200 logs
  where
    marker = "dpfExecutionLogs = "
