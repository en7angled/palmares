{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Palmares.Constants qualified as Constants
import Control.Monad.Logger (runNoLoggingT)
import Control.Monad.Reader (runReaderT)
import Data.Text.Encoding qualified as TE
import Database.Persist.Postgresql (ConnectionPool, createPostgresqlPool)
import Palmares.Admin.ApplySql (applyIndexes, applyRoles, assertIndexesValid, declaredIndexes)
import System.Environment (lookupEnv)
import Data.Aeson (encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Char8 qualified as LSB8
import Data.ByteString.Lazy qualified as B
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Palmares.DomainTypes.Core.Actions (AdminActionType (..), ProfileActionType (..), ProfileData (..), ProtocolActionType (..))
import Data.List (intercalate)
import Palmares.DomainTypes.Core.Types (AttestationType (..), ProfileType (..), attestationTypeText, parseAttestationType, parseProfileType, profileTypeText)
import GeniusYield.GYConfig
import GeniusYield.Imports
import GeniusYield.Types
import Palmares.Metrics.Catalog (metricCatalog)
import Palmares.Metrics.Doc (renderMetricsDoc)
import Palmares.Onchain.Blueprint (contractBlueprint)
import Palmares.Onchain.Protocol.Types (FeeConfig (..), OracleParams (..))
import Options.Applicative
import PlutusLedgerApi.V3 hiding (Committee) -- ours is a profile kind; Plutus's is the CIP-1694 committee datum
import System.Exit (die)
import Text.Read qualified as Text
import Palmares.TxBuilding.Context
import Palmares.TxBuilding.Interactions
import Palmares.TxBuilding.Lookups (queryOracleParams)
import Palmares.TxBuilding.Transactions
import Palmares.TxBuilding.Utils
import Palmares.TxBuilding.Validators (blueprintProtocolParams)
import Palmares.Utils
import Reconcile (ReconcileKoiosArgs (..), defaultReconcileKoiosArgs, runReconcileKoios)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)

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
  | WriteMetricsDoc FilePath
  | ReconcileKoios ReconcileKoiosArgs
  | ApplyIndexes
  | ApplyRoles
  | PauseProtocol
  | UnpauseProtocol
  | SetFees SetFeesArgs
  | SetMinUTxOValue Integer
  | SetDisputeDeposit Integer
  | RotateAdmin GYPubKeyHash
  | QueryOracle
  | UpdateProfile UpdateProfileArgs
  | IssueAttestation IssueAttestationArgs
  | AcceptAttestation AcceptAttestationArgs
  | CleanupDust
  deriving (Show)

data SetFeesArgs
  = ClearFees
  | UpdateFees
      { sfaFeeAddress :: String,
        sfaProfileCreationFee :: Integer,
        sfaAttestationFee :: Integer
      }
  deriving (Show)

data UpdateProfileArgs = UpdateProfileArgs
  { upaProfileId :: GYAssetClass,
    upaDescription :: Maybe T.Text,
    upaImageURI :: T.Text,
    upaOutputId :: Bool
  }
  deriving (Show)

data IssueAttestationArgs = IssueAttestationArgs
  { iaaSubjectProfileId :: GYAssetClass,
    iaaIssuerProfileId :: GYAssetClass,
    iaaKind :: AttestationType,
    iaaProfileData :: ProfileData,
    -- The issuance date is NOT an argument: it is derived from the chain tip, because the minting
    -- policy requires it to fall inside the transaction's validity interval and that interval is
    -- built from the tip. See 'Palmares.DomainTypes.Core.Actions.IssueAttestationAction'.
    iaaClaimedPeriod :: Maybe (GYTime, GYTime),
    iaaOutputId :: Bool
  }
  deriving (Show)

newtype AcceptAttestationArgs = AcceptAttestationArgs
  { acaAttestationId :: GYAssetClass
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

-- | Profile kind parser.
--
-- One @--kind@ option rather than a flag per constructor: there are six kinds now and a flag each
-- would need six short letters, two of which (@-p@, @-o@) the old two-kind version had already taken.
-- The spellings and the help text both come from 'ProfileType' itself, so adding a seventh kind needs
-- no edit here — which is the same "one naming site" rule the fee selector follows.
profileTypeParser :: Parser ProfileType
profileTypeParser =
  option
    (maybeReader (parseProfileType . T.pack))
    ( long "kind"
        <> short 'k'
        <> metavar "KIND"
        <> help ("Profile kind: " <> intercalate " | " (map (T.unpack . profileTypeText) allKinds))
    )
  where
    allKinds = [minBound .. maxBound] :: [ProfileType]

-- | @--kind@ for an attestation: what it asserts about its subject.
--
-- Required, with no default. An attestation whose kind the issuer did not state is not a weaker
-- record, it is an unreadable one — the read layer groups by this and a reader has nothing else to go
-- on. The help text is derived from the constructors, so a sixth kind appears here by itself.
attestationTypeParser :: Parser AttestationType
attestationTypeParser =
  option
    (maybeReader (parseAttestationType . T.pack))
    ( long "kind"
        <> short 'k'
        <> metavar "KIND"
        <> help ("What the attestation asserts: " <> intercalate " | " (map (T.unpack . attestationTypeText) allKinds))
    )
  where
    allKinds = [minBound .. maxBound] :: [AttestationType]

-- | @--claimed-period FROM..TO@, POSIX milliseconds, the same unit as @--posix@.
--
-- __ONE option and not two__, so the datum's "both bounds or neither" cannot be broken at the command
-- line. Two optional flags would let @--claimed-from@ through alone, and nothing downstream would
-- catch it: the conversion to the action is a pure function that cannot fail, and the validator
-- deliberately does not check this field at all.
claimedPeriodParser :: Parser (Maybe (GYTime, GYTime))
claimedPeriodParser =
  optional $
    option
      (maybeReader readPeriod)
      ( long "claimed-period"
          <> metavar "FROM..TO"
          <> help
            "Optional period the attestation CLAIMS — two POSIX millisecond timestamps separated by \
            \'..', e.g. 1709251200000..1767225600000. SELF-REPORTED: the chain cannot establish when \
            \an affiliation or a mandate began, so it is never published as verified and only its \
            \ordering is checked."
      )
  where
    readPeriod s = case break (== '.') s of
      (from, '.' : '.' : to) -> (,) <$> readTime from <*> readTime to
      _ -> Nothing
    readTime = fmap (timeFromPlutus . POSIXTime) . Text.readMaybe

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

-- | Parse a 28-byte hex key hash, through the same JSON form the API documents for @GYPubKeyHash@
-- ("Blake2b-224 public key hash, 28 bytes, hex-encoded"). Going through Aeson rather than decoding the
-- hex here means the CLI and the API cannot disagree about what a key hash looks like.
parsePubKeyHash :: String -> Maybe GYPubKeyHash
parsePubKeyHash s = Aeson.decode (B.fromStrict (LSB8.pack ("\"" <> s <> "\"")))

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
          "write-metrics-doc"
          ( info
              ( WriteMetricsDoc
                  <$> strOption
                    ( long "output"
                        <> short 'o'
                        <> metavar "FILE"
                        <> value "docs/metrics.md"
                        <> showDefault
                        <> help "Output file path for the generated metric documentation"
                    )
              )
              (progDesc "Render resources/metric-formulas.json and resources/metrics/*.sql to Markdown")
          )
        -- F1 check 6. No provider, no signing key, no validator config: CI runs this with no keys
        -- at all, which is the whole reason it is dispatched before provider loading.
        <> command
          "reconcile-koios"
          ( info
              ( ReconcileKoios
                  <$> ( ReconcileKoiosArgs
                          <$> strOption
                            ( long "palmares-api"
                                <> metavar "URL"
                                <> value ""
                                <> help "Our own API's base URL (default $PALMARES_API; required)"
                            )
                          <*> strOption
                            ( long "koios-api"
                                <> metavar "URL"
                                <> value ""
                                <> help "Koios base URL (default $KOIOS_API, else preprod.koios.rest/api/v1)"
                            )
                          <*> strOption
                            ( long "sample"
                                <> metavar "FILE"
                                <> value ""
                                <> help "The pinned sample (default config/reconcile-sample.preprod.json)"
                            )
                          <*> strOption
                            ( long "exceptions"
                                <> metavar "FILE"
                                <> value ""
                                <> help "The waiver file (default config/reconcile-exceptions.yaml)"
                            )
                          <*> strOption
                            ( long "out"
                                <> metavar "FILE"
                                <> value ""
                                <> help "Where to write the report (default out/divergences.json)"
                            )
                          <*> optional
                            ( option
                                auto
                                ( long "max-lag-seconds"
                                    <> metavar "N"
                                    <> help "Abort above this lag (default $PALMARES_READY_MAX_LAG_SECONDS, else 300)"
                                )
                            )
                          <*> optional
                            ( strOption
                                ( long "dump-snapshots"
                                    <> metavar "DIR"
                                    <> help "Also keep the fetched bodies under DIR/{koios,palmares}/"
                                )
                            )
                      )
              )
              (progDesc "Reconcile our governance index against Koios preprod (F1 check 6)")
          )
        -- The two SQL commands the service cannot run itself: one needs to be outside a
        -- transaction (CONCURRENTLY), the other needs the superuser db-sync owns. Both connect on
        -- PALMARES_ADMIN_CONN_STR and neither touches the chain, so both are dispatched before
        -- provider loading.
        <> command
          "apply-indexes"
          ( info
              (pure ApplyIndexes)
              (progDesc "Apply sql/indexes/001_gov_indexes.sql (CREATE INDEX CONCURRENTLY, autocommit)")
          )
        <> command
          "apply-roles"
          ( info
              (pure ApplyRoles)
              (progDesc "Apply sql/050_roles.sql and set the two role passwords from the environment")
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
          "set-dispute-deposit"
          ( info
              (SetDisputeDeposit <$> option auto (long "lovelace" <> short 'n' <> metavar "LOVELACE" <> help "Lovelace a new dispute must deposit (oracle opDisputeDeposit)"))
              (progDesc "Set the deposit (lovelace) a NEW dispute must lock; disputes already open keep the price in their own datum")
          )
        -- Inherited fix #2. No HTTP equivalent, on purpose: AdminActionType's FromJSON rejects it, so
        -- an action that changes who controls the protocol can only come from here, where the key
        -- that has to sign it already lives.
        <> command
          "rotate-admin"
          ( info
              ( RotateAdmin
                  <$> option
                    (maybeReader parsePubKeyHash)
                    ( long "new-admin"
                        <> metavar "PUBKEYHASH_HEX"
                        <> help "The 28-byte hex key hash of the role taking over the oracle"
                    )
              )
              ( progDesc
                  "Hand the oracle to a new admin (signed by the CURRENT admin; afterwards operation.prv no longer controls it)"
              )
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
          "issue-attestation"
          ( info
              ( IssueAttestation
                  <$> ( IssueAttestationArgs
                          <$> option (maybeReader parseAssetClass) (long "issued-to-profile-id" <> metavar "SUBJECT_PROFILE_ID" <> help "Profile ID of the subject the attestation is about")
                          <*> option (maybeReader parseAssetClass) (long "issued-by-profile-id" <> metavar "ISSUER_PROFILE_ID" <> help "Profile ID of the issuing profile")
                          <*> attestationTypeParser
                          <*> profileDataParser
                          <*> claimedPeriodParser
                          <*> outputIdParser
                      )
              )
              (progDesc "Issue an attestation about a subject profile (pending until countersigned)")
          )
        <> command
          "accept-attestation"
          ( info
              (AcceptAttestation . AcceptAttestationArgs <$> option (maybeReader parseAssetClass) (long "attestation-id" <> short 'i' <> metavar "ATTESTATION_ID" <> help "Attestation asset class"))
              (progDesc "Countersign a pending attestation as its subject")
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

issueAttestationToActionType :: IssueAttestationArgs -> ActionType
issueAttestationToActionType IssueAttestationArgs {iaaSubjectProfileId, iaaIssuerProfileId, iaaKind, iaaProfileData, iaaClaimedPeriod} =
  ProfileAction $
    IssueAttestationAction
      iaaSubjectProfileId
      iaaIssuerProfileId
      iaaKind
      iaaProfileData
      []
      iaaClaimedPeriod

acceptAttestationToActionType :: AcceptAttestationArgs -> ActionType
acceptAttestationToActionType AcceptAttestationArgs {acaAttestationId} =
  ProfileAction $ AcceptAttestationAction acaAttestationId

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
              fcAttestationFee = sfaAttestationFee
            }

-- Execute command function
executeCommand :: Either ProviderCtx TxBuildingContext -> GYExtendedPaymentSigningKey -> Command -> IO ()
executeCommand (Left pCtx) signKey cmd = case cmd of
  WriteBlueprint _ -> pure () -- Handled in main before provider loading
  WriteMetricsDoc _ -> pure () -- Handled in main before provider loading
  ReconcileKoios _ -> pure () -- Handled in main before provider loading
  ApplyIndexes -> pure () -- Handled in main before provider loading
  ApplyRoles -> pure () -- Handled in main before provider loading
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
  WriteMetricsDoc _ -> pure () -- Handled in main before provider loading
  ReconcileKoios _ -> pure () -- Handled in main before provider loading
  ApplyIndexes -> pure () -- Handled in main before provider loading
  ApplyRoles -> pure () -- Handled in main before provider loading
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
  SetDisputeDeposit n -> do
    printYellow $ "Setting dispute deposit to " <> show n <> " lovelace..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction (SetDisputeDepositAction n)) Nothing
    printGreen $ "Dispute deposit updated successfully! TxId: " <> show txId
  -- Inherited fix #2. Signed by the CURRENT admin, which is what the oracle validator's O1 requires,
  -- so this command is also the only proof that the key in `operation.prv` is still the live one.
  RotateAdmin newAdmin -> do
    printYellow $ "Rotating the oracle admin to " <> show newAdmin <> " ..."
    printYellow "This is signed by the CURRENT admin. After it confirms, operation.prv no longer controls the oracle."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction (RotateAdminAction newAdmin)) Nothing
    printGreen $ "Oracle admin rotated successfully! TxId: " <> show txId
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
    printGreen $ "  Dispute Deposit:    " <> show (opDisputeDeposit oracleParams) <> " lovelace"
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
  -- Attestation commands — routed through the Interaction pipeline
  IssueAttestation args -> do
    printYellow "Issuing attestation..."
    let actionType = issueAttestationToActionType args
    (_txId, mAssetClass) <- runActionWithPK txBuildingCtx signKey actionType Nothing
    printGreen "Attestation issued successfully!"
    if iaaOutputId args
      then putStrLn $ LSB8.unpack $ LSB8.toStrict $ Aeson.encode mAssetClass
      else printGreen $ "Attestation ID: " <> LSB8.unpack (LSB8.toStrict (Aeson.encode mAssetClass))
  AcceptAttestation args -> do
    printYellow "Accepting attestation..."
    let actionType = acceptAttestationToActionType args
    (_txId, mAssetClass) <- runActionWithPK txBuildingCtx signKey actionType Nothing
    printGreen "Attestation accepted successfully!"
    printGreen $ "Attestation ID: " <> LSB8.unpack (LSB8.toStrict (Aeson.encode mAssetClass))
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
    -- No provider, no signing key, no deployed-validators config — which is exactly what lets CI
    -- run this command to check the committed doc for drift.
    -- Exit codes: 0 clean or explained, 1 unexplained, 2 transport, 3 R10 abort. They are the
    -- command's whole contract with the nightly, so they are the process's exit status and not a
    -- line of output somebody has to grep.
    ReconcileKoios given -> do
      defaults <- defaultReconcileKoiosArgs
      code <- runReconcileKoios (withDefaults defaults given)
      if code == 0 then printGreen "reconcile-koios: no unexplained divergences" else printYellow ("reconcile-koios: exit " <> show code)
      exitWith (if code == 0 then ExitSuccess else ExitFailure code)
    -- No provider and no signing key either: these two talk to PostgreSQL only. Both are run by a
    -- one-shot Kubernetes Job with `backoffLimit`, so both must be safe to re-run and must fail
    -- the process rather than print a warning — a Job that exits 0 on a half-applied index set is
    -- a Job whose green tick means nothing.
    ApplyIndexes -> do
      pool <- adminPool
      printYellow "Applying sql/indexes/001_gov_indexes.sql (CONCURRENTLY, one statement at a time) ..."
      applySql "apply-indexes" (applyIndexes pool)
      -- And then the check no error code gives you: an interrupted CONCURRENTLY build leaves an
      -- INVALID index that IF NOT EXISTS will happily skip forever.
      invalid <- assertIndexesValid pool
      unless (null invalid) $
        die $
          "apply-indexes: "
            <> show (length invalid)
            <> " index(es) exist but are INVALID — DROP and re-create each, a retry will not fix them:"
            <> concatMap (\i -> "\n  " <> T.unpack i) invalid
      printGreen ("apply-indexes: all " <> show (length declaredIndexes) <> " declared indexes are valid")
    ApplyRoles -> do
      -- Read BEFORE the file is applied. A run that creates the two roles and then dies because a
      -- password is missing leaves two login roles that cannot log in, and the next run would have
      -- to be told that this is fine.
      ownerPw <- requiredEnv "PALMARES_OWNER_PASSWORD"
      roPw <- requiredEnv "PALMARES_RO_PASSWORD"
      pool <- adminPool
      printYellow "Applying sql/050_roles.sql ..."
      applySql "apply-roles" (applyRoles pool ownerPw roPw)
      printGreen "apply-roles: palmares_owner and palmares_ro are created, granted and given passwords"
    WriteMetricsDoc outputPath -> case metricCatalog of
      Left err -> die ("resources/metric-formulas.json does not parse: " <> err)
      Right formulas -> do
        printYellow $ "Writing metric documentation to " <> outputPath <> " ..."
        T.writeFile outputPath (renderMetricsDoc formulas)
        printGreen $ "Metric documentation written successfully to " <> outputPath
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

-- | A one-connection pool on @PALMARES_ADMIN_CONN_STR@, the @dbsync@ superuser's DSN.
--
-- Deliberately NOT @PG_CONN_STR@: that one is @palmares_ro@, which by design can neither create an
-- index on db-sync's tables nor create a role. One connection, because both commands are strictly
-- serial — @CREATE INDEX CONCURRENTLY@ on a second connection would just contend for the same
-- tables.
--
-- @runNoLoggingT@: persistent logs every statement, and @apply-roles@'s statements include the one
-- that carries a password.
adminPool :: IO ConnectionPool
adminPool =
  lookupEnv "PALMARES_ADMIN_CONN_STR" >>= \case
    Just s | not (null s) -> runNoLoggingT (createPostgresqlPool (TE.encodeUtf8 (T.pack s)) 1)
    _ ->
      die
        "PALMARES_ADMIN_CONN_STR is unset. These commands connect as the Postgres superuser, e.g.\n\
        \  PALMARES_ADMIN_CONN_STR=\"host=... user=dbsync password=... dbname=cexplorer port=5432\""

-- | An environment variable that has no sensible default, or a 'die' naming it.
requiredEnv :: String -> IO T.Text
requiredEnv name =
  lookupEnv name >>= \case
    Just v | not (null v) -> pure (T.pack v)
    _ -> die (name <> " is unset or empty. apply-roles needs both role passwords; it never invents one.")

-- | Report an apply's outcome, and 'die' on failure so the Job's exit status carries it.
applySql :: String -> IO (Either String Int) -> IO ()
applySql label act =
  act >>= \case
    Left e -> die (label <> ": " <> e)
    Right n -> printGreen (label <> ": " <> show n <> " statement(s) applied")

-- | Fill in whatever the flags left empty from the environment-derived defaults.
--
-- Spelled out rather than made the parser's @value@, because a default that lives in optparse
-- cannot read an environment variable: @--palmares-api@ unset must mean @$PALMARES_API@, and
-- optparse would have to be handed the variable's value before it has run.
withDefaults :: ReconcileKoiosArgs -> ReconcileKoiosArgs -> ReconcileKoiosArgs
withDefaults d given =
  ReconcileKoiosArgs
    { rkaPalmaresApi = orDefault (rkaPalmaresApi given) (rkaPalmaresApi d),
      rkaKoiosApi = orDefault (rkaKoiosApi given) (rkaKoiosApi d),
      rkaSample = orDefault (rkaSample given) (rkaSample d),
      rkaExceptions = orDefault (rkaExceptions given) (rkaExceptions d),
      rkaOut = orDefault (rkaOut given) (rkaOut d),
      rkaMaxLagSeconds = maybe (rkaMaxLagSeconds d) Just (rkaMaxLagSeconds given),
      rkaDumpSnapshots = rkaDumpSnapshots given
    }
  where
    orDefault "" fallback = fallback
    orDefault v _ = v
