{-# OPTIONS_GHC -Wno-partial-fields #-}

module Palmares.DomainTypes.Transfer.Types where

import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.List.Extra
import Data.Swagger (ToSchema (..), genericDeclareNamedSchema)
import Data.Swagger.Internal.Schema ()
import Data.Swagger.ParamSchema
import Data.Swagger.SchemaOptions (fromAesonOptions)
import Data.Text hiding (init, tail)
import Deriving.Aeson
import Palmares.DomainTypes.Core.Types
import GHC.Generics ()
import Palmares.Utils

data OrganizationProfileInformation
  = OrganizationProfileInformation
  { organizationId :: ProfileRefAC,
    organizationName :: Text,
    organizationDescription :: Text,
    organizationImageURI :: Text
  }
  deriving (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "organization", CamelToSnake]] OrganizationProfileInformation

instance ToSchema OrganizationProfileInformation where
  declareNamedSchema = genericDeclareNamedSchema organizationSchemaOptions
    where
      organizationSchemaOptions :: SchemaOptions
      organizationSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "organization"
            }

instance Show OrganizationProfileInformation where
  show :: OrganizationProfileInformation -> String
  show (OrganizationProfileInformation {..}) =
    Prelude.unlines
      [ "🏢 Organization Profile",
        "┌─────────────────────────────────────────────────────────────",
        "│ Name: " <> stringFromJSON organizationName,
        "│ Description: " <> stringFromJSON organizationDescription,
        "│ Image URI: " <> stringFromJSON organizationImageURI,
        "│ ID: " <> stringFromJSON organizationId,
        "└─────────────────────────────────────────────────────────────"
      ]

-- | Protocol status response DTO.
data ProtocolStatus = ProtocolStatus
  { protocolStatusOpPaused :: Bool,
    protocolStatusMinUtxoValue :: Integer,
    protocolStatusFeeConfig :: Maybe FeeConfigDTO,
    protocolStatusScriptHashes :: Maybe ScriptHashesDTO
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "protocolStatus", CamelToSnake]] ProtocolStatus

instance ToSchema ProtocolStatus where
  declareNamedSchema = genericDeclareNamedSchema $
    fromAesonOptions AesonTypes.defaultOptions {AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "protocolStatus"}

-- | Fee configuration response DTO.
data FeeConfigDTO = FeeConfigDTO
  { feeConfigProfileCreationFee :: Integer,
    feeConfigAttestationFee :: Integer,
    feeConfigFeeAddress :: Maybe Text
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "feeConfig", CamelToSnake]] FeeConfigDTO

instance ToSchema FeeConfigDTO where
  declareNamedSchema = genericDeclareNamedSchema $
    fromAesonOptions AesonTypes.defaultOptions {AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "feeConfig"}

-- | Script hashes of all deployed validators and the minting policy.
data ScriptHashesDTO = ScriptHashesDTO
  { scriptHashesMintingPolicy :: Text,
    scriptHashesProfilesValidator :: Text,
    scriptHashesAttestationsValidator :: Text,
    scriptHashesOracleValidator :: Text
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "scriptHashes", CamelToSnake]] ScriptHashesDTO

instance ToSchema ScriptHashesDTO where
  declareNamedSchema = genericDeclareNamedSchema $
    fromAesonOptions AesonTypes.defaultOptions {AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "scriptHashes"}
