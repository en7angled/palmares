{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module Palmares.TxBuilding.Validators where

import Palmares.Constants qualified as Constants
import Data.ByteString.Short qualified as SBS
import GeniusYield.Types
import Palmares.Onchain.Protocol
import Palmares.Onchain.Validators.AttestationsValidator qualified as AttestationsValidator (attestationsCompile)
import Palmares.Onchain.Validators.MintingPolicy qualified as MintingPolicy (mintingPolicyCompile)
import Palmares.Onchain.Validators.OracleNFTPolicy qualified as OracleNFTPolicy (oracleNFTPolicyCompile)
import Palmares.Onchain.Validators.OracleValidator qualified as OracleValidator (oracleCompile)
import Palmares.Onchain.Validators.ProfilesValidator qualified as ProfilesValidator (profilesCompile)
import PlutusLedgerApi.V1.Value qualified as V1
import PlutusLedgerApi.V3
-- PlutusTx for types/script compilation; PlutusTx.Prelude for term-level code with ($) hidden to avoid conflict.
import PlutusTx
import PlutusTx.Prelude hiding (($))

------------------------------------------------------------------------------------------------

-- * Define Profile Validator

------------------------------------------------------------------------------------------------

profilesValidatorPlutus :: CompiledCode (BuiltinData -> BuiltinUnit)
profilesValidatorPlutus = ProfilesValidator.profilesCompile

profilesValidatorGY :: GYScript 'PlutusV3
profilesValidatorGY = validatorFromPlutus profilesValidatorPlutus

profilesValidatorHashGY :: GYScriptHash
profilesValidatorHashGY = validatorHash profilesValidatorGY

profilesValidatorHashPlutus :: ScriptHash
profilesValidatorHashPlutus = validatorHashToPlutus profilesValidatorHashGY

------------------------------------------------------------------------------------------------

-- * Define Attestations Validator

------------------------------------------------------------------------------------------------

attestationsValidatorPlutus :: CompiledCode (BuiltinData -> BuiltinUnit)
attestationsValidatorPlutus = AttestationsValidator.attestationsCompile

attestationsValidatorGY :: GYScript 'PlutusV3
attestationsValidatorGY = validatorFromPlutus attestationsValidatorPlutus

attestationsValidatorHashGY :: GYScriptHash
attestationsValidatorHashGY = validatorHash attestationsValidatorGY

attestationsValidatorHashPlutus :: ScriptHash
attestationsValidatorHashPlutus = validatorHashToPlutus attestationsValidatorHashGY

------------------------------------------------------------------------------------------------

-- * Define Oracle Validator (unparameterized)

------------------------------------------------------------------------------------------------

oracleValidatorPlutus :: CompiledCode (BuiltinData -> BuiltinUnit)
oracleValidatorPlutus = OracleValidator.oracleCompile

oracleValidatorGY :: GYScript 'PlutusV3
oracleValidatorGY = validatorFromPlutus oracleValidatorPlutus

oracleValidatorHashGY :: GYScriptHash
oracleValidatorHashGY = validatorHash oracleValidatorGY

------------------------------------------------------------------------------------------------

-- * Define Oracle NFT Policy (parameterized by seed TxOutRef)

------------------------------------------------------------------------------------------------

-- | Compile the one-shot oracle NFT minting policy for a given seed UTxO.
compileOracleNFTPolicy :: TxOutRef -> GYScript 'PlutusV3
compileOracleNFTPolicy seedRef =
  validatorFromPlutus (OracleNFTPolicy.oracleNFTPolicyCompile seedRef)

------------------------------------------------------------------------------------------------

-- * Protocol Parameters

------------------------------------------------------------------------------------------------

-- | Build 'ProtocolParams' given the oracle NFT 'AssetClass'.
-- The oracle token is dynamic (depends on the oracle NFT minting tx)
-- so this cannot be a top-level constant.
mkProtocolParams :: V1.AssetClass -> ProtocolParams
mkProtocolParams =
  ProtocolParams
    profilesValidatorHashPlutus
    attestationsValidatorHashPlutus

-- | Protocol params with a placeholder oracle token, for blueprint generation only.
-- The actual oracle token is determined at deployment time.
blueprintProtocolParams :: ProtocolParams
blueprintProtocolParams = mkProtocolParams (V1.AssetClass (V1.CurrencySymbol "", V1.TokenName ""))

------------------------------------------------------------------------------------------------

-- * Define Minting Policy (parameterized by oracle token)

------------------------------------------------------------------------------------------------

-- | Compile the minting policy with the given oracle NFT 'AssetClass'.
-- The minting policy depends on 'ProtocolParams' which includes the oracle token,
-- so it must be compiled after the oracle NFT has been minted.
compileMintingPolicy :: V1.AssetClass -> GYScript 'PlutusV3
compileMintingPolicy oracleAC =
  validatorFromPlutus (MintingPolicy.mintingPolicyCompile (mkProtocolParams oracleAC))

------------------------------------------------------------------------------------------------

-- * Script Sizes (flat-encoded bytes)

------------------------------------------------------------------------------------------------

-- | Size of a compiled script in bytes (flat-encoded, as deployed on-chain)
compiledCodeSize :: CompiledCode a -> Int
compiledCodeSize cc = SBS.length (serialiseCompiledCode cc)

profilesValidatorSize :: Int
profilesValidatorSize = compiledCodeSize profilesValidatorPlutus

attestationsValidatorSize :: Int
attestationsValidatorSize = compiledCodeSize attestationsValidatorPlutus

oracleValidatorSize :: Int
oracleValidatorSize = compiledCodeSize oracleValidatorPlutus

-- | Size of the minting policy compiled with the given oracle NFT (parameterized script).
mintingPolicySize :: V1.AssetClass -> Int
mintingPolicySize oracleAC = compiledCodeSize (MintingPolicy.mintingPolicyCompile (mkProtocolParams oracleAC))

------------------------------------------------------------------------------------------------

-- * Export Validators

------------------------------------------------------------------------------------------------

exportProfilesValidator :: IO ()
exportProfilesValidator = writeScript @'PlutusV3 Constants.defaultProfilesValidatorFile $ validatorToScript profilesValidatorGY

exportAttestationsValidator :: IO ()
exportAttestationsValidator = writeScript @'PlutusV3 Constants.defaultAttestationsValidatorFile $ validatorToScript attestationsValidatorGY

exportOracleValidator :: IO ()
exportOracleValidator = writeScript @'PlutusV3 Constants.defaultOracleValidatorFile $ validatorToScript oracleValidatorGY

exportValidators :: IO ()
exportValidators = do
  exportProfilesValidator
  exportAttestationsValidator
  exportOracleValidator