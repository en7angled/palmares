{-# LANGUAGE ScopedTypeVariables #-}

-- | ANSI-colored console output helpers and JSON configuration file/env loaders.
module Palmares.Utils where

import Data.Aeson
import Data.Aeson qualified as Aeson
import qualified Data.Aeson.Types as AesonTypes
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List.Extra (dropPrefix)
import Data.Proxy (Proxy)
import Data.Swagger (ParamSchema, Schema, SwaggerType (SwaggerString), enum_, paramSchema, type_)
import Data.Swagger.SchemaOptions (SchemaOptions, fromAesonOptions)
import Data.Text (Text)
import Data.Text qualified as T
import Control.Lens ((&), (.~), (?~))
import System.Directory.Extra
import System.Environment
import System.Exit (die)
import Prelude

-- | Wrap a string with an ANSI color code and surrounding newlines.
colorString :: String -> String -> String
colorString code s = "\n\ESC[" ++ code ++ "m" ++ s ++ "\ESC[0m\n"

greenColorString :: String -> String
greenColorString = colorString "1;32"

orangeColorString :: String -> String
orangeColorString = colorString "1;33"

yellowColorString :: String -> String
yellowColorString = colorString "1;93"

blueColorString :: String -> String
blueColorString = colorString "1;94"

purpleColorString :: String -> String
purpleColorString = colorString "1;95"

cyanColorString :: String -> String
cyanColorString = colorString "1;96"

-- | Decode a JSON configuration file, returning 'Nothing' if the file does not exist.
decodeConfigFile :: (FromJSON a) => FilePath -> IO (Maybe a)
decodeConfigFile path = do
  fileExist <- doesFileExist path
  if fileExist
    then decodeFileStrict path
    else do
      putStrLn $ yellowColorString $ "File " <> path <> " does not exist"
      return Nothing

-- | Try to read a JSON-encoded configuration from an environment variable.
-- If the variable is present, decode its contents; otherwise, fall back to the given file path.
decodeConfigEnvOrFile :: (FromJSON a) => String -> FilePath -> IO (Maybe a)
decodeConfigEnvOrFile envName filePath = do
  mVal <- lookupEnv envName
  case mVal of
    Just raw -> do
      putStrLn $ yellowColorString $ "Parsing config from env var " <> show envName
      case eitherDecodeStrict (BS8.pack raw) of
        Right a -> return (Just a)
        Left err -> die $ "Decoding env var " <> envName <> " failed: " <> err
    Nothing -> do
      putStrLn $ yellowColorString $ "Parsing config from file " <> filePath
      decodeConfigFile filePath

-- | Encode a value to its JSON string representation, stripping the outer quotes.
stringFromJSON :: (ToJSON a) => a -> String
stringFromJSON a =
  let raw = BL8.unpack (Aeson.encode a)
   in case raw of
        ('"' : rest) | not (null rest) -> Prelude.init rest
        other -> other

-- | Build 'SchemaOptions' that strip a given prefix and convert to snake_case.
-- Eliminates the per-type boilerplate in 'ToSchema' instances.
--
-- @
-- instance ToSchema MyRequest where
--   declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "myReq")
-- @
mkStripPrefixSchemaOptions :: String -> SchemaOptions
mkStripPrefixSchemaOptions prefix =
  fromAesonOptions $
    AesonTypes.defaultOptions
      { AesonTypes.fieldLabelModifier = AesonTypes.camelTo2 '_' . dropPrefix prefix
      }

-- | A string 'ParamSchema' whose @enum_@ is the values' own JSON tags.
--
-- Swagger's generic derivation would print the Haskell constructor names, which for a
-- @ConstructorTagModifier@-carrying enum are not what goes on the wire. Reading the tags back out
-- of 'toJSON' keeps the wire strings in ONE place — the @ToJSON@ instance — so a documented
-- @enum@ cannot drift from the values the server actually accepts.
jsonEnumParamSchema :: forall a t. (ToJSON a, Enum a, Bounded a) => Proxy a -> ParamSchema t
jsonEnumParamSchema _ =
  mempty
    & type_ ?~ SwaggerString
    & enum_ ?~ fmap toJSON ([minBound .. maxBound] :: [a])

-- | The same enum as a 'Schema', for 'Data.Swagger.ToSchema' instances.
jsonEnumSchema :: (ToJSON a, Enum a, Bounded a) => Proxy a -> Schema
jsonEnumSchema p = mempty & paramSchema .~ jsonEnumParamSchema p

-- | Parse a query parameter by matching the value's own JSON tag, for the same reason.
--
-- The error string is the caller's, because it becomes an @ApiError@ code: the parameter's own
-- name is what tells a client which one it got wrong.
parseJsonEnumParam :: forall a. (ToJSON a, Enum a, Bounded a) => Text -> Text -> Either Text a
parseJsonEnumParam err t =
  maybe (Left err) Right (lookup t [(tag v, v) | v <- [minBound .. maxBound] :: [a]])
  where
    tag v = case toJSON v of
      Aeson.String s -> s
      other -> T.pack (BL8.unpack (Aeson.encode other))

-- | A value's own JSON tag, as 'Data.Text.Text'.
--
-- The counterpart to 'parseJsonEnumParam': wherever a value's wire string is needed outside JSON
-- — a SQL filter comparing against the string the response publishes, a CSV cell — it is read
-- back out of 'toJSON' rather than re-derived. A second snake-caser would publish @d_rep_active@
-- where the JSON says @active@, because these constructors carry a stripped prefix.
jsonTag :: (ToJSON a) => a -> Text
jsonTag v = case toJSON v of
  Aeson.String s -> s
  other -> T.pack (BL8.unpack (Aeson.encode other))
