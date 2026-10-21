-- | Default file paths for configuration, validators, and blueprint artifacts, plus other
-- cross-cutting default constants (e.g. app version, chain-sync fork-recovery margin).
module Palmares.Constants where

defaultAtlasCoreConfig :: FilePath
defaultAtlasCoreConfig = "config/config_atlas.json"

defaultTxBuildingContextFile :: FilePath
defaultTxBuildingContextFile = "config/config_palmares_validators.json"

defaultProfilesValidatorFile :: FilePath
defaultProfilesValidatorFile = "docs/validators/profiles_validator.plutus"

defaultMintingPolicyFile :: FilePath
defaultMintingPolicyFile = "docs/validators/minting_policy.plutus"

defaultAttestationsValidatorFile :: FilePath
defaultAttestationsValidatorFile = "docs/validators/attestations_validator.plutus"

defaultDisputesValidatorFile :: FilePath
defaultDisputesValidatorFile = "docs/validators/disputes_validator.plutus"

defaultOracleValidatorFile :: FilePath
defaultOracleValidatorFile = "docs/validators/oracle_validator.plutus"

defaultBlueprintFile :: FilePath
defaultBlueprintFile = "docs/generated/palmares-blueprint.json"

-- | Application version used in service probe responses.
appVersion :: String
appVersion = "1.0.0"

-- | Default fork-recovery depth (slots) rolled back on chain divergence. Overridable via ROLLBACK_MARGIN.
defaultRollbackMargin :: Integer
defaultRollbackMargin = 2160
