module Test.Helpers
  ( assert,
    queryOracle,
    failedWithTrace,
  )
where

import Control.Monad.Reader (runReaderT)
import GeniusYield.TxBuilder (GYTxMonadException)
import GeniusYield.TxBuilder.Query.Class (GYTxQueryMonad)
import Palmares.Onchain.Protocol.Types (OracleParams (..))
import Palmares.TxBuilding.Context (DeployedScriptsContext)
import Palmares.TxBuilding.Exceptions (traceCodesInRender)
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
--
-- __The parser is shared with the write API__ as of @OF-05@: 'traceCodesInRender' is what turns a
-- validator refusal into a @400 ScriptRefused@ naming the codes instead of "Not enough ADA in your
-- wallet". One parser, and the sixty-odd negative cases that call this function are its gate — which
-- is a better test than any the API could have on its own.
--
-- It is also stricter than the version this replaces: that one matched the quoted code as a SUBSTRING
-- of the first 200 characters of the log section, so a case asserting a code could in principle be
-- satisfied by a longer code containing it, and a script that emitted many traces before the
-- asserted one would read as a failure for the wrong reason. This compares list elements.
failedWithTrace :: String -> GYTxMonadException -> Bool
failedWithTrace code e = code `elem` traceCodesInRender (show e)
