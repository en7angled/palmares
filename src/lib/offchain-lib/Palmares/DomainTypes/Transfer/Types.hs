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

-- | A credential as the registry holds it: 28 bytes, and whether they are a key or a script.
--
-- Hex and deliberately NOT CIP-129: the oracle's admin and arbiter carry no governance __role__, and
-- CIP-129's header byte encodes exactly that, so rendering one would mean inventing a role the datum
-- does not have. A client that wants to compare these against a wallet compares the 28 bytes.
--
-- @is_script@ is not decoration: the two kinds take different proofs of control — a key credential
-- proves itself with a signature, a script credential by being spent at its own address — so a UI
-- that offers \"sign as admin\" to a script credential is offering something that cannot work.
data CredentialRef = CredentialRef
  { credHash :: Text,
    credIsScript :: Bool
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "cred", CamelToSnake]] CredentialRef

instance ToSchema CredentialRef where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "cred")

-- | The oracle's mutable parameters, read-only.
--
-- __Why this exists.__ Three separate frontend gaps were one missing route: a client could not show
-- the deposit it was about to ask for a signature on, could not show a dispute's deadline, and could
-- not name the arbiter who decides it. All three are fields of one datum nobody published.
--
-- __@dispute_deposit_lovelace@ and @dispute_timeout_ms@ are the price and the clock for a NEW
-- dispute.__ An OPEN dispute's are history: both are copied into its own datum when it opens, so
-- repricing the protocol never moves an existing deadline or reprices an existing deposit. To show
-- what a dispute cost, read that dispute's own @deposit@ from query-api; to show what opening one
-- will cost, read these.
--
-- The two fee fields are @null@ TOGETHER — they come from one optional @FeeConfig@, and the deployed
-- default carries none, which means both fees are zero rather than unknown. The fee ADDRESS is
-- deliberately not published: rendering it needs a network id this layer does not have, and no
-- screen needs it.
data OracleParamsResponse = OracleParamsResponse
  { oracleDisputeDepositLovelace :: Integer,
    oracleDisputeTimeoutMs :: Integer,
    oracleMinUtxoLovelace :: Integer,
    oracleArbiter :: CredentialRef,
    oracleAdmin :: CredentialRef,
    oracleProfileCreationFeeLovelace :: Maybe Integer,
    oracleAttestationFeeLovelace :: Maybe Integer
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "oracle", CamelToSnake]] OracleParamsResponse

instance ToSchema OracleParamsResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "oracle")
