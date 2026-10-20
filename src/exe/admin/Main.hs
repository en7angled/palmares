{-# LANGUAGE RecordWildCards #-}

module Main where

import Palmares.Constants qualified as Constants
import Control.Monad.Reader (runReaderT)
import Data.Aeson (encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Char8 qualified as LSB8
import Data.ByteString.Lazy qualified as B
import Data.Char (toLower, toUpper)
import Data.Text qualified as T
import Palmares.DomainTypes.Core.Actions (AdminActionType (..), ProfileActionType (..), ProfileData (..), ProtocolActionType (..))
import Palmares.DomainTypes.Core.Types (ProfileType (..))
import GeniusYield.GYConfig
import GeniusYield.Imports
import GeniusYield.Types
import Palmares.Onchain.Blueprint (contractBlueprint)
import Palmares.Onchain.Protocol.Types (FeeConfig (..), OracleParams (..))
import Options.Applicative
import PlutusLedgerApi.V3
import System.Exit (die)
import Text.Read qualified as Text
import Palmares.TxBuilding.Context
import Palmares.TxBuilding.Interactions
import Palmares.TxBuilding.Lookups (queryOracleParams)
import Palmares.TxBuilding.Transactions
import Palmares.TxBuilding.Utils
import Palmares.TxBuilding.Validators (blueprintProtocolParams)
import Palmares.Utils

mnemonicFilePath :: FilePath
mnemonicFilePath = "operation.prv"

printYellow :: String -> IO ()
printYellow = putStrLn . yellowColorString

printGreen :: String -> IO ()
printGreen = putStrLn . greenColorString

-- Command data types
-- NOTE: DeleteProfile command was intentionally removed to preserve lineage integrity.
-- An attestation record is a permanent historical fact and must stay resolvable.
data Command
  = DeployReferenceScripts
  | WriteBlueprint FilePath
  | PauseProtocol
  | UnpauseProtocol
  | SetFees SetFeesArgs
  | SetMinUTxOValue Integer
  | QueryOracle
  | UpdateProfile UpdateProfileArgs
  | AwardAchievement AwardAchievementArgs
  | AcceptAchievement AcceptAchievementArgs
  | CleanupDust
  deriving (Show)

data SetFeesArgs
  = ClearFees
  | UpdateFees
      { sfaFeeAddress :: String,
        sfaProfileCreationFee :: Integer,
        sfaAchievementFee :: Integer
      }
  deriving (Show)

data UpdateProfileArgs = UpdateProfileArgs
  { upaProfileId :: GYAssetClass,
    upaDescription :: Maybe T.Text,
    upaImageURI :: T.Text,
    upaOutputId :: Bool
  }
  deriving (Show)

data AwardAchievementArgs = AwardAchievementArgs
  { awaAwardedToProfileId :: GYAssetClass,
    awaAwardedByProfileId :: GYAssetClass,
    awaProfileData :: ProfileData,
    awaAchievementDate :: GYTime,
    awaOutputId :: Bool
  }
  deriving (Show)

newtype AcceptAchievementArgs = AcceptAchievementArgs
  { acaAchievementId :: GYAssetClass
  }
  deriving (Show)

-- Profile data parser
profileDataParser :: Parser ProfileData
profileDataParser =
  ProfileData
    <$> fmap
      T.pack
      ( strOption
          ( long "name"
              <> metavar "NAME"
              <> help "Profile name"
          )
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "description"
              <> metavar "DESCRIPTION"
              <> help "Profile description"
          )
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "image-uri"
              <> metavar "IMAGE_URI"
              <> help "Profile image URI"
          )
      )

-- Profile type parser
profileTypeParser :: Parser ProfileType
profileTypeParser =
  flag'
    Practitioner
    ( long "practitioner"
        <> short 'p'
        <> help "Profile type (Practitioner or Organization)"
    )
    <|> flag'
      Organization
      ( long "organization"
          <> short 'o'
          <> help "Profile type (Practitioner or Organization)"
      )

-- POSIX time parser
posixTimeParser :: Parser GYTime
posixTimeParser =
  timeFromPlutus . POSIXTime
    <$> option
      auto
      ( long "posix"
          <> short 't'
          <> metavar "POSIX_TIME"
          <> help "POSIX timestamp"
      )

-- Optional POSIX time parser
optionalPosixTimeParser :: Parser (Maybe GYTime)
optionalPosixTimeParser =
  optional $
    timeFromPlutus . POSIXTime
      <$> option
        auto
        ( long "end-posix"
            <> metavar "END_POSIX_TIME"
            <> help "Optional end POSIX timestamp"
        )

-- Asset class parser helper function
parseAssetClass :: String -> Maybe GYAssetClass
parseAssetClass s = Aeson.decode (B.fromStrict (LSB8.pack s))

-- Asset class parser
assetClassParser :: Parser GYAssetClass
assetClassParser =
  option
    (maybeReader parseAssetClass)
    ( long "asset-class"
        <> short 'a'
        <> metavar "ASSET_CLASS"
        <> help "Asset class identifier"
    )

outputIdParser :: Parser Bool
outputIdParser =
  flag
    False
    True
    ( long "output-id"
        <> short 'o'
        <> help "Output the asset ID in a parseable format"
    )

-- Set fees parser (--clear-fees flag or individual fee fields)
setFeesParser :: Parser Command
setFeesParser =
  fmap SetFees $
    flag' ClearFees (long "clear-fees" <> help "Clear fee configuration (no fees)")
      <|> ( UpdateFees
              <$> strOption (long "fee-address" <> metavar "ADDRESS" <> help "Bech32 address to receive fees")
              <*> option auto (long "profile-fee" <> metavar "LOVELACE" <> help "Profile creation fee in lovelace")
              <*> option auto (long "attestation-fee" <> metavar "LOVELACE" <> help "Attestation fee in lovelace")
          )

-- Main command parser
commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "deploy-reference-scripts"
        ( info
            (pure DeployReferenceScripts)
            (progDesc "Deploy reference scripts for the protocol (includes oracle deployment)")
        )
        <> command
          "write-blueprint"
          ( info
              ( WriteBlueprint
                  <$> strOption
                    ( long "output"
                        <> short 'o'
                        <> metavar "FILE"
                        <> value Constants.defaultBlueprintFile
                        <> showDefault
                        <> help "Output file path for the CIP-57 contract blueprint JSON"
                    )
              )
              (progDesc "Write the CIP-57 contract blueprint JSON to a file")
          )
        <> command
          "pause-protocol"
          ( info
              (pure PauseProtocol)
              (progDesc "Pause the protocol (set opPaused = True in oracle)")
          )
        <> command
          "unpause-protocol"
          ( info
              (pure UnpauseProtocol)
              (progDesc "Unpause the protocol (set opPaused = False in oracle)")
          )
        <> command
          "set-fees"
          ( info
              setFeesParser
              (progDesc "Set or clear fee configuration in the oracle")
          )
        <> command
          "set-min-utxo-value"
          ( info
              (SetMinUTxOValue <$> option auto (long "lovelace" <> short 'n' <> metavar "LOVELACE" <> help "Minimum lovelace for protocol state outputs (oracle opMinUTxOValue)"))
              (progDesc "Set minimum UTxO value (lovelace) for protocol state outputs in the oracle")
          )
        <> command
          "query-oracle"
          ( info
              (pure QueryOracle)
              (progDesc "Display current oracle parameters (read-only)")
          )
        <> command
          "update-profile"
          ( info
              ( UpdateProfile
                  <$> ( UpdateProfileArgs
                          <$> assetClassParser
                          <*> optional (fmap T.pack (strOption (long "description" <> metavar "DESCRIPTION" <> help "New profile description (omit to keep current)")))
                          <*> fmap T.pack (strOption (long "image-uri" <> metavar "IMAGE_URI" <> help "New image URI"))
                          <*> outputIdParser
                      )
              )
              (progDesc "Update profile metadata (description, image)")
          )
        <> command
          "award-achievement"
          ( info
              ( AwardAchievement
                  <$> ( AwardAchievementArgs
                          <$> option (maybeReader parseAssetClass) (long "awarded-to-profile-id" <> metavar "AWARDED_TO_PROFILE_ID" <> help "Profile ID of the practitioner receiving the achievement")
                          <*> option (maybeReader parseAssetClass) (long "awarded-by-profile-id" <> metavar "AWARDED_BY_PROFILE_ID" <> help "Profile ID of the awarder (org or practitioner)")
                          <*> profileDataParser
                          <*> posixTimeParser
                          <*> outputIdParser
                      )
              )
              (progDesc "Award an achievement to a practitioner")
          )
        <> command
          "accept-achievement"
          ( info
              (AcceptAchievement . AcceptAchievementArgs <$> option (maybeReader parseAssetClass) (long "achievement-id" <> short 'i' <> metavar "ACHIEVEMENT_ID" <> help "Achievement asset class"))
              (progDesc "Accept an achievement (practitioner acknowledges)")
          )
        <> command
          "cleanup-dust"
          ( info
              (pure CleanupDust)
              (progDesc "Sweep dust/griefing UTxOs from validator addresses (permissionless — anyone can run this)")
          )
    )

-- Action type conversion functions
updateProfileToActionType :: UpdateProfileArgs -> ActionType
updateProfileToActionType UpdateProfileArgs {upaProfileId, upaDescription, upaImageURI} =
  ProfileAction $ UpdateProfileAction upaProfileId upaDescription upaImageURI

awardAchievementToActionType :: AwardAchievementArgs -> ActionType
awardAchievementToActionType AwardAchievementArgs {awaAwardedToProfileId, awaAwardedByProfileId, awaProfileData, awaAchievementDate} =
  ProfileAction $ AwardAchievementAction awaAwardedToProfileId awaAwardedByProfileId awaProfileData [] awaAchievementDate

acceptAchievementToActionType :: AcceptAchievementArgs -> ActionType
acceptAchievementToActionType AcceptAchievementArgs {acaAchievementId} =
  ProfileAction $ AcceptAchievementAction acaAchievementId

-- | Convert SetFeesArgs to the AdminActionType for the Interaction pipeline
setFeesToAdminAction :: SetFeesArgs -> AdminActionType
setFeesToAdminAction ClearFees = SetFeesAction Nothing
setFeesToAdminAction UpdateFees {..} =
  let gyAddr = unsafeAddressFromText (T.pack sfaFeeAddress)
      plutusAddr = addressToPlutus gyAddr
   in SetFeesAction $
        Just
          FeeConfig
            { fcFeeAddress = plutusAddr,
              fcProfileCreationFee = sfaProfileCreationFee,
              fcAttestationFee = sfaAchievementFee
            }

-- Execute command function
executeCommand :: Either ProviderCtx TxBuildingContext -> GYExtendedPaymentSigningKey -> Command -> IO ()
executeCommand (Left pCtx) signKey cmd = case cmd of
  WriteBlueprint _ -> pure () -- Handled in main before provider loading
  QueryOracle -> do
    printYellow "No transaction building context found."
    printYellow "Please run 'deploy-reference-scripts' first to set up the system."
  DeployReferenceScripts -> do
    printYellow "Deploying reference scripts..."
    deployedScriptsCtx <- deployReferenceScripts pCtx signKey
    B.writeFile Constants.defaultTxBuildingContextFile (encode . toJSON $ deployedScriptsCtx)
    printGreen $ "Reference scripts deployed successfully! \n\t" <> "File: " <> Constants.defaultTxBuildingContextFile
  _ -> do
    printYellow "No transaction building context found."
    printYellow "Please run 'deploy-reference-scripts' first to set up the system."
executeCommand (Right txBuildingCtx) signKey cmd = case cmd of
  WriteBlueprint _ -> pure () -- Handled in main before provider loading
  DeployReferenceScripts -> do
    printYellow "Deploying reference scripts..."
    deployedScriptsCtx <- deployReferenceScripts (providerCtx txBuildingCtx) signKey
    B.writeFile Constants.defaultTxBuildingContextFile (encode . toJSON $ deployedScriptsCtx)
    printGreen $ "Reference scripts deployed successfully! \n\t" <> "File: " <> Constants.defaultTxBuildingContextFile
  -- Oracle admin commands — routed through the Interaction pipeline
  PauseProtocol -> do
    printYellow "Pausing protocol..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction PauseProtocolAction) Nothing
    printGreen $ "Protocol paused successfully! TxId: " <> show txId
  UnpauseProtocol -> do
    printYellow "Unpausing protocol..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction UnpauseProtocolAction) Nothing
    printGreen $ "Protocol unpaused successfully! TxId: " <> show txId
  SetFees args -> do
    printYellow "Updating fee configuration..."
    let adminAction = setFeesToAdminAction args
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction adminAction) Nothing
    printGreen $ "Fee configuration updated successfully! TxId: " <> show txId
  SetMinUTxOValue n -> do
    printYellow $ "Setting min UTxO value to " <> show n <> " lovelace..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction (SetMinUTxOValueAction n)) Nothing
    printGreen $ "Min UTxO value updated successfully! TxId: " <> show txId
  -- Query oracle — read-only, does not go through the Interaction pipeline
  QueryOracle -> do
    printYellow "Querying oracle parameters..."
    let pCtx = providerCtx txBuildingCtx
        dCtx = deployedScriptsCtx txBuildingCtx
    (oracleParams, oracleRef, oracleVal) <- runQuery pCtx $ runReaderT queryOracleParams dCtx
    printGreen "=== Oracle Parameters ==="
    printGreen $ "  UTxO Ref:           " <> show oracleRef
    printGreen $ "  Value:              " <> show oracleVal
    printGreen $ "  Admin PKH:          " <> show (opAdminPkh oracleParams)
    printGreen $ "  Paused:             " <> show (opPaused oracleParams)
    printGreen $ "  Min UTxO Value:     " <> show (opMinUTxOValue oracleParams) <> " lovelace"
    case opFeeConfig oracleParams of
      Nothing -> printGreen "  Fee Config:          None"
      Just fc -> do
        printGreen "  Fee Config:"
        printGreen $ "    Fee Address:         " <> show (fcFeeAddress fc)
        printGreen $ "    Profile Creation Fee: " <> show (fcProfileCreationFee fc) <> " lovelace"
        printGreen $ "    Attestation Fee:      " <> show (fcAttestationFee fc) <> " lovelace"
  UpdateProfile args -> do
    printYellow "Updating profile..."
    let actionType = updateProfileToActionType args
    (_txId, mAssetClass) <- runActionWithPK txBuildingCtx signKey actionType Nothing
    printGreen "Profile updated successfully!"
    if upaOutputId args
      then putStrLn $ LSB8.unpack $ LSB8.toStrict $ Aeson.encode mAssetClass
      else printGreen $ "Profile ID: " <> LSB8.unpack (LSB8.toStrict (Aeson.encode mAssetClass))
  -- Achievement commands — routed through the Interaction pipeline
  AwardAchievement args -> do
    printYellow "Awarding achievement..."
    let actionType = awardAchievementToActionType args
    (_txId, mAssetClass) <- runActionWithPK txBuildingCtx signKey actionType Nothing
    printGreen "Achievement awarded successfully!"
    if awaOutputId args
      then putStrLn $ LSB8.unpack $ LSB8.toStrict $ Aeson.encode mAssetClass
      else printGreen $ "Achievement ID: " <> LSB8.unpack (LSB8.toStrict (Aeson.encode mAssetClass))
  AcceptAchievement args -> do
    printYellow "Accepting achievement..."
    let actionType = acceptAchievementToActionType args
    (_txId, mAssetClass) <- runActionWithPK txBuildingCtx signKey actionType Nothing
    printGreen "Achievement accepted successfully!"
    printGreen $ "Achievement ID: " <> LSB8.unpack (LSB8.toStrict (Aeson.encode mAssetClass))
  CleanupDust -> do
    printYellow "Sweeping dust UTxOs from validator addresses..."
    let actionType = ProtocolAction CleanupDustAction
    (txId, _) <- runActionWithPK txBuildingCtx signKey actionType Nothing
    printGreen $ "Dust cleanup successful! TxId: " <> show txId

main :: IO ()
main = do
  printGreen "Palmares - Cardano governance track record"

  -- Parse command line arguments
  cmd <-
    execParser $
      info
        (commandParser <**> helper)
        ( fullDesc
            <> progDesc "A command-line tool for the Palmares attestation protocol on Cardano. Deploys reference scripts, writes the CIP-57 blueprint, administers the oracle, and issues or accepts attestations."
            <> header "Palmares - Cardano governance track record"
        )

  -- Handle commands that don't require blockchain providers
  case cmd of
    WriteBlueprint outputPath -> do
      printYellow $ "Writing CIP-57 contract blueprint to " <> outputPath <> " ..."
      B.writeFile outputPath (encodePretty $ contractBlueprint blueprintProtocolParams)
      printGreen $ "Blueprint written successfully to " <> outputPath
    _ -> executeOnchainCommand cmd

-- | Execute commands that require blockchain providers and signing keys
executeOnchainCommand :: Command -> IO ()
executeOnchainCommand cmd = do
  mTxBuildingContext <- decodeConfigEnvOrFile "DEPLOYED_VALIDATORS_CONFIG" Constants.defaultTxBuildingContextFile
  case mTxBuildingContext of
    Nothing -> do
      printYellow "No transaction building context found, please run deploy-reference-scripts first"
    Just _txBuildingContext -> do
      printYellow "Transaction building context found, executing command"

  printYellow $ "Reading signing key file from " <> mnemonicFilePath
  signKey <- readMnemonicFile mnemonicFilePath

  printYellow "Reading atlas configuration file ..."
  atlasConfig <- maybe (die "Atlas configuration file not found") return =<< decodeConfigEnvOrFile "ATLAS_CORE_CONFIG" Constants.defaultAtlasCoreConfig

  printYellow "Loading Providers ..."
  withCfgProviders atlasConfig (Text.read @GYLogNamespace "palmares") $ \providers -> do
    let pCtx = ProviderCtx atlasConfig providers

    case mTxBuildingContext of
      Nothing -> do
        printYellow "No deployed scripts context found, please run deploy-reference-scripts first"
        executeCommand (Left pCtx) signKey cmd
      Just validatorsCtx -> do
        let txBuildingContext = TxBuildingContext {deployedScriptsCtx = validatorsCtx, providerCtx = pCtx}
        executeCommand (Right txBuildingContext) signKey cmd
