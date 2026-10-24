{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Application monad and context for the query API server.
--
-- The context is deliberately small: a connection pool, the cached chain freshness, and the two
-- numbers @\/ready@ decides on. There is __no Cardano provider__ and __no deployed-script
-- context__, because this service never queries the chain — D-1 says every row comes from a
-- @palmares@ view or the one matview, and the inherited live-query handlers that needed a
-- provider are gone. The consequence is worth stating: query-api boots with nothing but a
-- Postgres DSN, so it needs no provider key and no @config_atlas.json@, which is both one less
-- secret on a public read service and what makes the smoke script runnable anywhere.
--
-- There is also __no auth context__. query-api is public (rate limiting is the BFF's job), and a
-- configured-but-unenforced credential is worse than none: it reads as protection.
module QueryAppMonad where

import Control.Concurrent.STM (TVar)
import Control.Exception (SomeException, try)
import Control.Monad.Reader
import Data.Text (Text)
import Database.Persist.Sql (ConnectionPool, SqlPersistT)
import Palmares.DomainTypes.Transfer.QueryResponses (AttestationStatus)
import Palmares.WebAPI.Envelope (ErrorCode (..), errorCodeToHttpStatus)
import Palmares.WebAPI.Errors (mkServantErr)
import Query.Gov (Freshness, runGovRead)
import Servant
import System.IO (hPutStrLn, stderr)

-- | Shared environment for all query-API request handlers.
data QueryAppContext = QueryAppContext
  { -- | The db-sync database. Read-only in effect: every statement is a @SELECT@ over @palmares@.
    pgPool :: ConnectionPool,
    -- | The last successful poll of @palmares.sync_state@. One poller feeds @\/ready@, @\/status@
    -- and the response headers, so the service has exactly one answer to \"how fresh are we\" and
    -- the hot path adds no query.
    freshness :: TVar (Maybe Freshness),
    -- | How far behind db-sync's tip the ATTESTATION projector is, in seconds, or 'Nothing' when
    -- there is no evidence either way. Fed by the same poller as 'freshness', from a different
    -- service's cursor — nothing in @palmares.sync_state@ says whether @attest-sync@ is alive.
    attestLag :: TVar (Maybe AttestationStatus),
    -- | @PALMARES_NETWORK_NAME@. Compared against @meta.network_name@ by @\/ready@: an instance
    -- pointed at the wrong network would answer every question confidently and wrongly.
    expectedNetwork :: Text,
    -- | @PALMARES_READY_MAX_LAG_SECONDS@: the lag at which @\/ready@ turns red.
    readyMaxLag :: Int,
    -- | @PALMARES_AMBER_LAG_SECONDS@: the lag at which a UI should warn. A band, never the probe.
    amberLag :: Int
  }

newtype QueryAppMonad a = QueryAppMonad {unAppMonad :: ReaderT QueryAppContext Servant.Handler a}
  deriving (Functor, Applicative, Monad)

-- | Run a 'QueryAppMonad' computation with the given context.
runAppMonad :: QueryAppContext -> QueryAppMonad a -> Servant.Handler a
runAppMonad ctx app = runReaderT (unAppMonad app) ctx

instance MonadIO QueryAppMonad where
  liftIO :: IO a -> QueryAppMonad a
  liftIO = QueryAppMonad . liftIO

instance MonadReader QueryAppContext QueryAppMonad where
  ask :: QueryAppMonad QueryAppContext
  ask = QueryAppMonad ask

  local :: (QueryAppContext -> QueryAppContext) -> QueryAppMonad a -> QueryAppMonad a
  local f (QueryAppMonad app) = QueryAppMonad (local f app)

-- | Serve an 'ErrorCode' with the status it maps to.
throwApi :: ErrorCode -> QueryAppMonad a
throwApi code = QueryAppMonad (throwError (mkServantErr (errorCodeToHttpStatus code) code))

-- | Run a governance read in one 'runGovRead' transaction, mapping a database failure to 503.
--
-- 503 and not 500, because a failed read here is almost always the database being unreachable or
-- a view missing after a db-sync migration — conditions a client should retry and a load balancer
-- should route around, not a bug in the request. The exception text goes to stderr and never to
-- the client: it names tables, columns and sometimes the DSN.
runRead :: SqlPersistT IO a -> QueryAppMonad a
runRead act = do
  pool <- asks pgPool
  r <- liftIO (try (runGovRead pool act))
  case r of
    Right a -> pure a
    Left (e :: SomeException) -> do
      liftIO (hPutStrLn stderr ("[query] read failed: " <> show e))
      throwApi DbUnavailable
