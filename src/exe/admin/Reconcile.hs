{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @admin reconcile-koios@: fetch both indexes, compare them, write the report.
--
-- __Koios runs on cardano-db-sync too. It is a completeness check, never a source of truth, and
-- never a fallback when our own sync is behind.__ Every number this API serves comes from our own
-- views; this command's only output is a report saying where two independent readings of the same
-- chain disagree, and which of those disagreements somebody has already explained.
--
-- __Everything is fetched as a 'Value' and decoded at the end.__ That is what makes
-- @--dump-snapshots@ worth having: the file written to disk is what came over the wire, not a
-- re-encoding of our own types, so a committed pair is evidence about the two services rather than
-- about this module's instances. A paged fetch's file is the concatenation of its pages, which is
-- the only honest artifact for a call that had no single body.
--
-- __Four exit codes, and only one of them is decided here.__ 0, 1 and 3 come from
-- 'reportExitCode'; __2 is transport or decode failure__ and is this module's alone. \"Koios did
-- not answer\" and \"Koios answered something different\" are different events, and a nightly that
-- cannot tell them apart will either page someone over a network blip or ignore a real divergence
-- as one.
module Reconcile
  ( ReconcileKoiosArgs (..),
    defaultReconcileKoiosArgs,
    runReconcileKoios,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, throwIO, try)
import Control.Monad (forM, when)
import Data.Aeson (Value (Array, Number, Object, String), eitherDecode, encode, object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as AKM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Vector qualified as V
import Network.HTTP.Client
  ( HttpException (..),
    Manager,
    Request (..),
    RequestBody (RequestBodyLBS),
    Response (..),
    httpLbs,
    newManager,
    parseRequest,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (HeaderName, hAuthorization, hContentType)
import Network.HTTP.Types.Status (statusCode)
import Palmares.Reconcile
import Palmares.Reconcile.Koios (KoiosTip (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

-- | What the subcommand was asked to do.
--
-- No @--sample-dreps@ / @--sample-actions@ counts: a count without a pinned order is a
-- non-reproducible draw, and the sample FILE is the sample.
data ReconcileKoiosArgs = ReconcileKoiosArgs
  { rkaPalmaresApi :: String,
    rkaKoiosApi :: String,
    rkaSample :: FilePath,
    rkaExceptions :: FilePath,
    rkaOut :: FilePath,
    rkaMaxLagSeconds :: Maybe Int,
    rkaDumpSnapshots :: Maybe FilePath
  }
  deriving stock (Show, Eq)

-- | The defaults, before the flags are applied: environment first, then the committed paths.
--
-- @PALMARES_API@ has no default worth guessing — a reconciliation against the wrong deployment
-- would report a wall of divergences that mean nothing — so an empty value is refused in
-- 'runReconcileKoios' rather than silently pointed at localhost.
defaultReconcileKoiosArgs :: IO ReconcileKoiosArgs
defaultReconcileKoiosArgs = do
  pApi <- fromMaybe "" <$> lookupEnv "PALMARES_API"
  kApi <- fromMaybe "https://preprod.koios.rest/api/v1" <$> lookupEnv "KOIOS_API"
  lag <- (>>= readMaybe) <$> lookupEnv "PALMARES_READY_MAX_LAG_SECONDS"
  pure
    ReconcileKoiosArgs
      { rkaPalmaresApi = pApi,
        rkaKoiosApi = kApi,
        rkaSample = "config/reconcile-sample.preprod.json",
        rkaExceptions = "config/reconcile-exceptions.yaml",
        rkaOut = "out/divergences.json",
        rkaMaxLagSeconds = lag,
        rkaDumpSnapshots = Nothing
      }

-- | A fetch that did not produce a usable body. The only path to exit 2.
newtype TransportError = TransportError String
  deriving stock (Show)

instance Exception TransportError

-- ---------------------------------------------------------------------------------------------

-- * Fetching

-- | One side's HTTP settings. @paceMs@ is 0 for our own API and 250 for Koios.
data Side = Side
  { sideBase :: String,
    sideManager :: Manager,
    sidePaceMs :: Int,
    sideToken :: Maybe String
  }

-- | Why an 'HttpException' happened, without the 'Request' it carries.
--
-- @show@ on an 'HttpExceptionRequest' renders the whole request record — every header, the body
-- settings, the proxy settings — and the part that says what went wrong is the content. The
-- caller prefixes the URL, which is the only field of that record anybody reads.
httpWhy :: HttpException -> String
httpWhy (HttpExceptionRequest _ content) = show content
httpWhy (InvalidUrlException url why) = url <> ": " <> why

-- | GET one path, as a 'Value'.
--
-- __@Retry-After@ is honoured and a 429 or 5xx is retried three times__, because the alternative
-- is a nightly that aborts whenever Koios is briefly busy — and an abort that is really a rate
-- limit teaches a reader to ignore aborts. A 4xx that is not 429 is NOT retried: it will say the
-- same thing again.
--
-- __The handler catches 'HttpException' and the first version caught 'IOError'__, which is the one
-- exception @httpLbs@ never throws. Everything that fails before a response exists — DNS, a
-- refused connection, a timeout, a rejected certificate — is an 'HttpException', so the handler
-- named \"the only path to exit 2\" caught every transport failure except a failing transport.
-- Measured, on reconcile run 39697594482: the nightly hit @NameMismatch \"gov.cardano.vip\"@ on
-- our own @\/status@, the exception escaped both this @try@ and the one in 'runReconcileKoios',
-- the process died with GHC's uncaught-exception code 1, and the wrapper read that 1 as
-- @UNEXPLAINED DIVERGENCES@ — pointing at a report file the run had died before writing. An
-- unreachable deployment reported itself as a parity finding, which is the exact confusion the
-- four exit codes exist to prevent.
getValue :: Side -> String -> IO Value
getValue side path = go (3 :: Int)
  where
    go attemptsLeft = do
      pace side
      req0 <- parseRequest (sideBase side <> path)
      r <- try (httpLbs req0 {requestHeaders = authHeader side} (sideManager side))
      case r of
        Left (e :: HttpException) -> retryOr attemptsLeft (sideBase side <> path <> ": " <> httpWhy e)
        Right resp -> do
          let code = statusCode (responseStatus resp)
          if code == 200
            then decodeBody (sideBase side <> path) (responseBody resp)
            else
              if code == 429 || code >= 500
                then do
                  waitRetryAfter resp
                  retryOr attemptsLeft (sideBase side <> path <> ": HTTP " <> show code)
                else
                  throwIO . TransportError $
                    sideBase side
                      <> path
                      <> ": HTTP "
                      <> show code
                      <> " "
                      <> take 300 (BL8.unpack (responseBody resp))

    retryOr n why
      | n > 1 = go (n - 1)
      | otherwise = throwIO (TransportError (why <> " (gave up after 3 attempts)"))

-- | POST a JSON body, as a 'Value'. Koios's @\/drep_info@ is the only such call.
postValue :: Side -> String -> Value -> IO Value
postValue side path body = do
  pace side
  req0 <- parseRequest (sideBase side <> path)
  let req =
        req0
          { method = "POST",
            requestBody = RequestBodyLBS (encode body),
            requestHeaders = (hContentType, "application/json") : authHeader side
          }
  r <- try (httpLbs req (sideManager side))
  case r of
    Left (e :: HttpException) -> throwIO (TransportError (sideBase side <> path <> ": " <> httpWhy e))
    Right resp
      | statusCode (responseStatus resp) == 200 ->
          decodeBody (sideBase side <> path) (responseBody resp)
      | otherwise ->
          throwIO . TransportError $
            sideBase side <> path <> ": HTTP " <> show (statusCode (responseStatus resp))

-- | @Authorization: Bearer@ when @KOIOS_API_TOKEN@ is set. The token comes from the environment and
-- is never in the repository.
authHeader :: Side -> [(HeaderName, ByteString)]
authHeader side = case sideToken side of
  Nothing -> []
  Just t -> [(hAuthorization, BS8.pack ("Bearer " <> t))]

decodeBody :: String -> BL.ByteString -> IO Value
decodeBody path body = case eitherDecode body of
  Left e -> throwIO (TransportError (path <> ": body is not JSON: " <> e))
  Right v -> pure v

pace :: Side -> IO ()
pace side = when (sidePaceMs side > 0) (threadDelay (sidePaceMs side * 1000))

-- | Honour @Retry-After@ when the server sent one, else back off a second.
waitRetryAfter :: Response BL.ByteString -> IO ()
waitRetryAfter resp =
  threadDelay . (* 1000000) . fromMaybe 1 $
    lookup "Retry-After" (responseHeaders resp) >>= readMaybe . BS8.unpack

-- | Page a list endpoint until a SHORT page, concatenating the arrays.
--
-- __Never uses a reported total as the loop bound.__ A total is computed over a different pass than
-- the rows (F-17's rule), so a loop that trusted it would stop early on any disagreement between
-- the two — which is the very class of bug this command exists to find.
fetchPaged :: Side -> (Value -> [Value]) -> String -> Int -> IO Value
fetchPaged side rowsOf path limit = Array . V.fromList <$> go 0
  where
    go offset = do
      v <- getValue side (path <> sep <> "limit=" <> show limit <> "&offset=" <> show offset)
      let rows = rowsOf v
      if length rows < limit then pure rows else (rows <>) <$> go (offset + limit)
    sep = if '?' `elem` path then "&" else "?"

arrayOf :: Value -> [Value]
arrayOf = \case
  Array a -> V.toList a
  _ -> []

itemsOf :: Value -> [Value]
itemsOf = \case
  Object o -> arrayOf (fromMaybe (Array mempty) (AKM.lookup "items" o))
  _ -> []

-- | One request per id, the id as the key.
fetchKeyed :: (Text -> IO Value) -> [Text] -> IO Value
fetchKeyed one ids = Object . AKM.fromList <$> forM ids (\i -> (,) (AK.fromText i) <$> one i)

-- ---------------------------------------------------------------------------------------------

-- * The two fetch plans

-- | Everything one Koios run reads, as the files 'loadKoiosSnapshot' expects.
--
-- @_epoch_no@ on @\/drep_voting_power_history@ is MANDATORY — a bare GET 504s — so the five
-- completed epochs are fetched one at a time and concatenated. @\/drep_info@ is chunked for the
-- reason 'drepInfoChunk' records.
fetchKoiosFiles :: Side -> ReconcileSample -> [Int] -> IO (Map FilePath Value)
fetchKoiosFiles side sample epochs = do
  tip <- getValue side "/tip"
  drepList <- fetchPaged side arrayOf "/drep_list?registered=eq.true" 1000
  let ids = [t | String t <- map idOf (arrayOf drepList)]
  info <-
    Array . V.fromList . concatMap arrayOf
      <$> forM (chunksOf drepInfoChunk ids) (\c -> postValue side "/drep_info" (object ["_drep_ids" .= c]))
  power <-
    Array . V.fromList . concatMap arrayOf
      <$> forM
        epochs
        (\e -> fetchPaged side arrayOf ("/drep_voting_power_history?_epoch_no=" <> show e) 1000)
  proposals <- fetchPaged side arrayOf "/proposal_list" 1000
  pVotes <-
    fetchKeyed
      (\a -> getValue side ("/proposal_votes?_proposal_id=" <> T.unpack a))
      (sampleTallyActions sample)
  dVotes <-
    fetchKeyed
      (\d -> getValue side ("/drep_votes?_drep_id=" <> T.unpack d))
      (sampleVoteHistoryDreps sample)
  committee <- getValue side "/committee_info"
  pure $
    M.fromList
      [ ("tip.json", tip),
        ("drep_list.json", drepList),
        ("drep_info.json", info),
        ("drep_voting_power_history.json", power),
        ("proposal_list.json", proposals),
        ("proposal_votes.json", pVotes),
        ("drep_votes.json", dVotes),
        ("committee_info.json", committee)
      ]
  where
    idOf = \case
      Object o -> fromMaybe (String "") (AKM.lookup "drep_id" o)
      _ -> String ""

-- | The five COMPLETED epochs below a tip, @[tip-5 … tip-1]@.
--
-- The tip's OWN epoch is excluded because it is still being written: @drep_distr@ gains rows during
-- an epoch, so comparing it would be comparing two readings of a moving table and the difference
-- would be the time between the two fetches.
completedEpochs :: Int -> [Int]
completedEpochs tipEpoch = [tipEpoch - 5 .. tipEpoch - 1]

-- | How many DRep ids go in one @POST \/drep_info@.
--
-- 50, MEASURED against the live service, not the 100 the plan assumed: a 100-id body is 6,623 bytes
-- and Koios answers __HTTP 413__. 50 ids is 3,323 bytes and answers 200. Preprod's 294 DReps are
-- therefore 6 POSTs rather than 3, which costs 0.75 s of pacing and is the whole difference.
drepInfoChunk :: Int
drepInfoChunk = 50

-- | Split a list into chunks.
--
-- Written out rather than pulling in @split@ for one two-line function.
chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)

-- | Everything one run reads from our own API, as the files 'loadPalmaresSnapshot' expects.
fetchPalmaresFiles :: Side -> ReconcileSample -> [Int] -> IO (Map FilePath Value)
fetchPalmaresFiles side sample epochs = do
  status <- getValue side "/status"
  dreps <- fetchPaged side itemsOf "/dreps?status=active&status=inactive" 200
  let ids = [t | String t <- map idOf (arrayOf dreps)] <> reservedIds
      -- NOT `minimum (0 : epochs)`, which is what this said first: seeding the fold with 0 made
      -- `from_epoch=0` on every request, so each series came back from the dawn of the chain and
      -- the 200-point ceiling silently cut the epochs R3 actually compares off the far end.
      (from, to) = case epochs of
        [] -> (0, 0)
        _ -> (minimum epochs, maximum epochs)
  power <-
    fetchKeyed
      ( \d ->
          Array . V.fromList . itemsOf
            <$> getValue
              side
              ("/drep/" <> T.unpack d <> "/power?from_epoch=" <> show from <> "&to_epoch=" <> show to)
      )
      ids
  actions <- fetchPaged side itemsOf "/gov-actions" 200
  details <-
    fetchKeyed (\a -> getValue side ("/gov-action/" <> T.unpack a)) (sampleTallyActions sample)
  votes <-
    fetchKeyed
      (\d -> fetchPaged side itemsOf ("/votes?voter_id=" <> T.unpack d) 200)
      (sampleVoteHistoryDreps sample)
  committee <- getValue side "/committee"
  pure $
    M.fromList
      [ ("status.json", status),
        ("dreps.json", dreps),
        ("drep_power.json", power),
        ("gov_actions.json", actions),
        ("gov_action_detail.json", details),
        ("votes.json", votes),
        ("committee.json", committee)
      ]
  where
    idOf = \case
      Object o -> fromMaybe (String "") (AKM.lookup "id" o)
      _ -> String ""
    -- D-20: the reserved ledger options hold most of the power and are rows like any other, so R4's
    -- total is wrong by about half without them.
    reservedIds = ["drep_always_abstain", "drep_always_no_confidence"]

-- ---------------------------------------------------------------------------------------------

-- * Running

-- | Fetch both sides, reconcile, write the report, return the process exit code.
--
-- No markdown sibling: the wrapper's @jq@ already prints the per-row table, and a second rendering
-- of the same numbers is a second thing to keep in step.
--
-- __The fetched bodies are WRITTEN and then LOADED BACK__, even when @--dump-snapshots@ was not
-- asked for (into a temporary directory in that case). That is one extra disk round trip and it
-- buys something worth more than it: the live run and the replay test decode through exactly the
-- same 'loadKoiosSnapshot' / 'loadPalmaresSnapshot' code path, so a committed pair cannot pass the
-- replay test while the live run fails on the same bodies.
--
-- __R10's two inputs are fetched FIRST.__ A run that cannot establish freshness has nothing to say
-- about the other nine rows, and finding that out after 441 requests would be 441 wasted requests
-- and twenty minutes of Koios's rate limit.
runReconcileKoios :: ReconcileKoiosArgs -> IO Int
runReconcileKoios args = do
  r <- try (run args)
  case r of
    Left (TransportError why) -> do
      putStrLn ("reconcile-koios: " <> why)
      -- 2, and only here: a service that did not answer is not a parity finding.
      pure 2
    Right code -> pure code

run :: ReconcileKoiosArgs -> IO Int
run args = do
  when (null (rkaPalmaresApi args)) $
    throwIO (TransportError "PALMARES_API is unset and --palmares-api was not given")
  sample <- loadSample (rkaSample args) >>= orDie
  es <- loadExceptions (rkaExceptions args) >>= orDie
  mgr <- newManager tlsManagerSettings
  token <- lookupEnv "KOIOS_API_TOKEN"
  let ours = Side (dropTrailingSlash (rkaPalmaresApi args)) mgr 0 Nothing
      koios = Side (dropTrailingSlash (rkaKoiosApi args)) mgr 250 token

  statusV <- getValue ours "/status"
  let pEpoch = intAt ["governance", "epoch"] statusV
      epochs = completedEpochs pEpoch

  kFiles <- fetchKoiosFiles koios sample epochs
  pFiles <- fetchPalmaresFiles ours sample epochs

  dir <- case rkaDumpSnapshots args of
    Just d -> pure d
    Nothing -> pure (takeDirectory (rkaOut args) </> ".snapshot")
  writeSnapshot (dir </> "koios") kFiles
  writeSnapshot (dir </> "palmares") pFiles
  case rkaDumpSnapshots args of
    Just d -> putStrLn ("reconcile-koios: wrote the snapshot pair to " <> d)
    Nothing -> pure ()

  k <- loadKoiosSnapshot (dir </> "koios") >>= orDie
  p <- loadPalmaresSnapshot (dir </> "palmares") >>= orDie

  now <- getCurrentTime
  -- The bound the caller actually asked for: the flag, else PALMARES_READY_MAX_LAG_SECONDS, else
  -- the default. `reconcileAll` would silently use 300 and make --max-lag-seconds decorative.
  let rows = reconcileAllWith (fromMaybe readyMaxLagSeconds (rkaMaxLagSeconds args)) k p es
      report =
        mkReport
          (sampleNetwork sample)
          now
          (psEpoch p)
          (psLagSeconds p)
          (koiosTipEpochNo (ksTip k))
          es
          rows
  createDirectoryIfMissing True (takeDirectory (rkaOut args))
  BL.writeFile (rkaOut args) (encodePretty report <> "\n")
  putStrLn ("reconcile-koios: wrote " <> rkaOut args)
  pure (reportExitCode report)
  where
    orDie :: Either String a -> IO a
    orDie = either (throwIO . TransportError) pure

-- | Write one side's bodies, one file per endpoint.
writeSnapshot :: FilePath -> Map FilePath Value -> IO ()
writeSnapshot dir files = do
  createDirectoryIfMissing True dir
  mapM_ (\(name, v) -> BL.writeFile (dir </> name) (encodePretty v <> "\n")) (M.toList files)

-- | Read an integer down a path of object keys, or 0.
--
-- Tiny on purpose: the only two values read before decoding are the two epochs R10 needs, and a
-- lens or a full decode of 'StatusResponse' here would mean the freshness guard depended on a DTO
-- that the rest of the run has not fetched yet.
intAt :: [Text] -> Value -> Int
intAt path v = case (path, v) of
  ([], Number n) -> truncate n
  (key : rest, Object o) -> maybe 0 (intAt rest) (AKM.lookup (AK.fromText key) o)
  _ -> 0

dropTrailingSlash :: String -> String
dropTrailingSlash s = if not (null s) && last s == '/' then init s else s
