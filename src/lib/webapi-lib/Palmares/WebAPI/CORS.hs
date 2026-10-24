{-# LANGUAGE OverloadedStrings #-}

-- | CORS middleware driven by an explicit origin allowlist (fail-closed).
-- Only origins present in @CORS_ALLOWED_ORIGINS@ receive CORS headers; every
-- other origin gets none, so the browser blocks the cross-origin response.
module Palmares.WebAPI.CORS where

import Data.ByteString (ByteString)
import qualified Data.List
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Types as HttpTypes
import Network.HTTP.Types.Header (hOrigin)
import Network.Wai
import Network.Wai.Middleware.Cors
import System.Environment (lookupEnv)

-- | Resolved CORS configuration. 'allowCredentials' is currently always 'False'
-- (frontend is same-origin / proxied / token-based).
data CorsConfig = CorsConfig
  { allowedOrigins :: [ByteString],
    allowCredentials :: Bool
  }
  deriving (Eq, Show)

-- | Parse a comma-separated origin allowlist: trims whitespace, drops empties.
parseCorsOrigins :: String -> [ByteString]
parseCorsOrigins raw =
  [ TE.encodeUtf8 t
  | chunk <- T.splitOn "," (T.pack raw),
    let t = T.strip chunk,
    not (T.null t)
  ]

-- | Read @CORS_ALLOWED_ORIGINS@; unset/empty yields an empty allowlist
-- (no cross-origin allowed). Credentials are disabled.
getCorsConfigFromEnv :: IO CorsConfig
getCorsConfigFromEnv = do
  mOrigins <- lookupEnv "CORS_ALLOWED_ORIGINS"
  return
    CorsConfig
      { allowedOrigins = maybe [] parseCorsOrigins mOrigins,
        allowCredentials = False
      }

-- | The freshness headers every response carries, named here so the browser can read them.
--
-- A response header is invisible to @fetch()@ unless it is in @Access-Control-Expose-Headers@.
-- Without this list the server would send the chain point on every cross-origin response and the
-- staleness chip would silently show nothing — a failure with no error anywhere to find it by.
freshnessExposedHeaders :: [HttpTypes.HeaderName]
freshnessExposedHeaders =
  [ "X-Chain-Epoch",
    "X-Chain-Slot",
    "X-Chain-Block-Time",
    "X-Data-Lag-Seconds",
    "X-Data-Source",
    -- `CS-07` added these three and did not add them here, which is the exact failure the paragraph
    -- above describes: the server sends the projector's state on every response and a browser client
    -- cannot read any of it, with nothing logged anywhere to find it by.
    "X-Attest-Slot",
    "X-Attest-Lag-Seconds",
    "X-Attest-State"
  ]

-- | Policy: reflect the request 'Origin' only if it is in the allowlist,
-- otherwise emit no CORS headers.
corsPolicy :: CorsConfig -> Request -> Maybe CorsResourcePolicy
corsPolicy cfg req =
  case Data.List.lookup hOrigin (requestHeaders req) of
    Just o
      | o `elem` allowedOrigins cfg ->
          Just
            simpleCorsResourcePolicy
              { corsOrigins = Just ([o], allowCredentials cfg),
                corsMethods = ["GET", "POST", "PUT", "OPTIONS", "DELETE"],
                corsRequestHeaders = simpleHeaders <> [HttpTypes.hAuthorization],
                corsExposedHeaders = Just $ simpleHeaders <> [HttpTypes.hAuthorization] <> freshnessExposedHeaders,
                corsVaryOrigin = True,
                corsRequireOrigin = False,
                corsIgnoreFailures = False,
                corsMaxAge = Just 600
              }
    _ -> Nothing

-- | WAI middleware applying the allowlist CORS policy.
mkCorsMiddleware :: CorsConfig -> Middleware
mkCorsMiddleware cfg = cors (corsPolicy cfg)
