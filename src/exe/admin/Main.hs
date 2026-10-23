{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Cardano.Mnemonic qualified as Mnemonic
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
import Palmares.DomainTypes.Core.Actions (AdminActionType (..), ClaimWitness, ProfileActionType (..), ProfileData (..), ProtocolActionType (..))
import Data.List (intercalate)
import Palmares.DomainTypes.Core.Types (AttestationType (..), ProfileType (..), attestationTypeText, parseAttestationType, parseProfileType, profileTypeText)
import GeniusYield.GYConfig
import GeniusYield.Imports
import GeniusYield.Types
import Palmares.Metrics.Catalog (metricCatalog)
import Palmares.Metrics.Doc (renderMetricsDoc)
import Palmares.Onchain.Blueprint (contractBlueprint)
import Palmares.Onchain.Protocol.Types (ClaimedCredential (ClaimedDRep), FeeConfig (..), OracleParams (..))
import Options.Applicative
import PlutusLedgerApi.V3 hiding (Committee) -- ours is a profile kind; Plutus's is the CIP-1694 committee datum
import System.Directory (doesFileExist)
import Web.HttpApiData qualified as Web
import System.Exit (die)
import System.Posix.Files (setFileMode)
import Text.Read qualified as Text
import Palmares.TxBuilding.Context
import Palmares.TxBuilding.Conversions (claimCredentialToText)
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
  | SetDisputeTimeout Integer
  | RotateAdmin RotateArgs
  | RotateArbiter RotateArgs
  | SubmitTx SubmitTxArgs
  | QueryOracle
  | UpdateProfile UpdateProfileArgs
  | IssueAttestation IssueAttestationArgs
  | AcceptAttestation AcceptAttestationArgs
  | CleanupDust
  | NewOperatorKey
  | OperatorAddress
  | -- | Which mnemonic to witness with; 'Nothing' is @operation.prv@.
    --
    -- __Added with the two-party handover (ADR 0005).__ @O5@ needs the INCOMING side's witness, and
    -- the incoming side is normally a different person on a different machine with their own
    -- @operation.prv@ — so the default is right and stays the default. On ONE machine it was not:
    -- the only way to sign as the other party was to move @operation.prv@ aside and put the other
    -- key in its place, which is a manual file swap around the file that controls the protocol.
    -- @new-operator-key@ already refuses to overwrite that file for the same reason.
    SignTx (Maybe FilePath)
  deriving (Show)

-- | What a handover needs: who is taking over, and whether to stop before signing.
--
-- Shared by @rotate-admin@ and @rotate-arbiter@ because the two differ only in which field moves.
data RotateArgs = RotateArgs
  { -- | The incoming credential. A key hash unless @--script@ says the same 28 bytes are a script.
    rotCredential :: Credential,
    -- | Print the unsigned transaction and stop, instead of signing and submitting it.
    --
    -- __The default is the one that cannot work alone.__ @O5@ requires the INCOMING side to prove
    -- control in the same transaction, and this process holds only the outgoing key, so building,
    -- signing and submitting in one go produces a transaction the chain refuses — which is what
    -- @rotate-admin@ did before this flag existed. So the flagless form now REFUSES rather than
    -- submitting something doomed, and says which two commands finish the job.
    rotBuildOnly :: Bool,
    -- | How the INCOMING side proves control, when its credential is a script. Unused for a key.
    rotIncomingWitness :: Maybe ClaimWitness,
    -- | How the CURRENT admin proves control, when 'OracleParams.opAdmin' is already a script.
    --
    -- Only the two rotation commands take this. The other six admin commands pass 'Nothing' and so
    -- assume a key admin, which is every deployment at genesis; wiring the same flag into them is
    -- mechanical and waits for somebody who needs it. Rotation is the one that cannot wait, because
    -- it is how you get back to a key.
    rotAdminWitness :: Maybe ClaimWitness
  }
  deriving (Show)

-- | Submit a transaction built earlier, with witnesses collected from other parties.
data SubmitTxArgs = SubmitTxArgs
  { -- | File holding the hex CBOR that @--build-only@ printed.
    staTxFile :: FilePath,
    -- | Files holding witness hex, one per co-signer, as @sign-tx@ prints it. Repeatable.
    staWitnessFiles :: [FilePath]
  }
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
      (fromStr, '.' : '.' : toStr) -> (,) <$> readTime fromStr <*> readTime toStr
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

-- | A 'ClaimWitness' straight from its own wire form, which is the laziest correct reader: the type
-- already has the tagged 'FromJSON' that @\/claim-credential@ takes, so all three shapes — @key@,
-- @simple_script@, @plutus_script@ — arrive with no new parsing code and no second encoding to keep
-- in step.
parseClaimWitnessJSON :: String -> Maybe ClaimWitness
parseClaimWitnessJSON = Aeson.decode . B.fromStrict . LSB8.pack

-- | The incoming side of a handover: 28 bytes, plus whether they name a script.
--
-- __A flag and not a prefix, because the bytes do not say.__ A payment credential is a 28-byte
-- blake2b hash either way; only the address header distinguishes a key hash from a script hash, and
-- a bare hash has no header. Guessing would be worse than asking: handing the oracle to
-- @PubKeyCredential h@ when @h@ is a script hash brings the protocol to a stop that only @O5@
-- prevents — which is exactly why @O5@ exists and why this flag must be explicit.
rotateArgsParser :: Parser RotateArgs
rotateArgsParser =
  RotateArgs
    <$> ( credentialFrom
            <$> option
              (maybeReader parsePubKeyHash)
              ( long "new-credential"
                  <> metavar "HASH28_HEX"
                  <> help "The 28-byte hex hash of the credential taking over"
              )
            <*> switch
              ( long "script"
                  <> help "Those bytes are a SCRIPT hash (e.g. a native multisig), not a key hash"
              )
        )
    <*> switch
      ( long "build-only"
          <> help "Print the unsigned transaction hex and stop, for the incoming side to sign with sign-tx"
      )
    <*> optional
      ( option
          (maybeReader parseClaimWitnessJSON)
          ( long "incoming-witness"
              <> metavar "FILE_OR_JSON"
              <> help "How a SCRIPT incoming credential proves control: {\"tag\":\"simple_script\",\"script\":…}"
          )
      )
    <*> optional
      ( option
          (maybeReader parseClaimWitnessJSON)
          ( long "admin-witness"
              <> metavar "FILE_OR_JSON"
              <> help "How the CURRENT admin proves control, if it is already a script credential"
          )
      )
  where
    credentialFrom pkh isScript =
      let raw = pubKeyHashToPlutus pkh
       in if isScript
            then ScriptCredential (ScriptHash (getPubKeyHash raw))
            else PubKeyCredential raw

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
        "new-operator-key"
        ( info
            (pure NewOperatorKey)
            ( progDesc
                "Generate a fresh 24-word operator mnemonic into operation.prv and print its address (refuses to overwrite)"
            )
        )
        <> command
          "operator-address"
          ( info
              (pure OperatorAddress)
              ( progDesc
                  "Print what operation.prv identifies: the address to fund before deploying, in both \
                  \bech32 and raw-hex form, and the key's CIP-129 DRep id — the value \
                  \scripts/smoke_attest_flow.sh takes as ATTEST_SMOKE_DREP_ID."
              )
          )
        <> command
          "sign-tx"
          ( info
              ( SignTx
                  <$> optional
                    ( strOption
                        ( long "key-file"
                            <> metavar "FILE"
                            <> help "Mnemonic file to sign with. Default operation.prv"
                        )
                    )
              )
              ( progDesc
                  "Reads an unsigned transaction's CBOR hex on STDIN and writes the CIP-30 witness set CBOR hex \
                  \to STDOUT, signed with operation.prv unless --key-file says otherwise. Nothing else goes to \
                  \STDOUT. No provider and no deployed-validators config: this is the signer \
                  \scripts/smoke_attest_flow.sh takes as PALMARES_SIGN_CMD."
              )
          )
        <> command
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
        <> command
          "set-dispute-timeout"
          ( info
              ( SetDisputeTimeout
                  <$> option
                    auto
                    ( long "milliseconds"
                        <> short 'm'
                        <> metavar "MS"
                        <> help "How long a NEW dispute may sit undecided before ANYONE may close it (oracle opDisputeTimeoutMs). 2592000000 = 30 days"
                    )
              )
              (progDesc "Set the stale-dispute clock for NEW disputes; disputes already open keep their own deadline in their datum")
          )
        -- Inherited fix #2. No HTTP equivalent, on purpose: AdminActionType's FromJSON rejects it, so
        -- an action that changes who controls the protocol can only come from here, where the key
        -- that has to sign it already lives.
        <> command
          "rotate-admin"
          ( info
              (RotateAdmin <$> rotateArgsParser)
              ( progDesc
                  "Hand the oracle to a new admin. Two steps: --build-only here, sign-tx by the incoming side, then submit-tx"
              )
          )
        -- ADR 0005. Separate from the admin because writing verdicts and repricing the protocol are
        -- different powers with different blast radii; genesis sets them to the same credential, so
        -- this command is what makes the split real for an operator who wants it.
        <> command
          "rotate-arbiter"
          ( info
              (RotateArbiter <$> rotateArgsParser)
              ( progDesc
                  "Hand the dispute-verdict power to a new credential, leaving the admin alone. Same two steps as rotate-admin"
              )
          )
        -- The other half of --build-only, and the reason the two-party flow needs no new encoding:
        -- the tx hex is what the write routes already hand a wallet, and the witness hex is what
        -- sign-tx already prints.
        <> command
          "submit-tx"
          ( info
              ( SubmitTx
                  <$> ( SubmitTxArgs
                          <$> strOption
                            ( long "tx"
                                <> metavar "FILE"
                                <> help "File holding the hex CBOR printed by a --build-only run"
                            )
                          <*> many
                            ( strOption
                                ( long "witness"
                                    <> metavar "FILE"
                                    <> help "File holding witness hex from sign-tx. Repeat once per co-signer"
                                )
                            )
                      )
              )
              ( progDesc
                  "Sign a transaction built earlier with operation.prv, attach collected witnesses, and submit it"
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
  -- The three `main` dispatches before it loads a provider, so they never arrive here. Listed all
  -- the same, and the clause above gets away with not listing them only because it ends in `_ ->`:
  -- this one enumerates, so omitting them made it non-exhaustive, which is what `-Wall` reported.
  NewOperatorKey -> pure () -- Handled in main before provider loading
  OperatorAddress -> pure () -- Handled in main before provider loading
  SignTx _ -> pure () -- Handled in main before provider loading
  DeployReferenceScripts -> do
    printYellow "Deploying reference scripts..."
    deployedScriptsCtx <- deployReferenceScripts (providerCtx txBuildingCtx) signKey
    B.writeFile Constants.defaultTxBuildingContextFile (encode . toJSON $ deployedScriptsCtx)
    printGreen $ "Reference scripts deployed successfully! \n\t" <> "File: " <> Constants.defaultTxBuildingContextFile
  -- Oracle admin commands — routed through the Interaction pipeline
  PauseProtocol -> do
    printYellow "Pausing protocol..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction PauseProtocolAction Nothing) Nothing
    printGreen $ "Protocol paused successfully! TxId: " <> show txId
  UnpauseProtocol -> do
    printYellow "Unpausing protocol..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction UnpauseProtocolAction Nothing) Nothing
    printGreen $ "Protocol unpaused successfully! TxId: " <> show txId
  SetFees args -> do
    printYellow "Updating fee configuration..."
    let adminAction = setFeesToAdminAction args
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction adminAction Nothing) Nothing
    printGreen $ "Fee configuration updated successfully! TxId: " <> show txId
  SetMinUTxOValue n -> do
    printYellow $ "Setting min UTxO value to " <> show n <> " lovelace..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction (SetMinUTxOValueAction n) Nothing) Nothing
    printGreen $ "Min UTxO value updated successfully! TxId: " <> show txId
  SetDisputeDeposit n -> do
    printYellow $ "Setting dispute deposit to " <> show n <> " lovelace..."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction (SetDisputeDepositAction n) Nothing) Nothing
    printGreen $ "Dispute deposit updated successfully! TxId: " <> show txId
  SetDisputeTimeout ms -> do
    printYellow $ "Setting the stale-dispute clock to " <> show ms <> " ms (" <> show (ms `div` 86_400_000) <> " days)..."
    printYellow "Disputes already open keep their own deadline: it is recorded in each dispute's datum at open time."
    (txId, _) <- runActionWithPK txBuildingCtx signKey (AdminAction (SetDisputeTimeoutAction ms) Nothing) Nothing
    printGreen $ "Dispute timeout updated successfully! TxId: " <> show txId
  -- Inherited fix #2. Signed by the CURRENT admin, which is what the oracle validator's O1 requires,
  -- so this command is also the only proof that the key in `operation.prv` is still the live one.
  RotateAdmin args -> runRotation txBuildingCtx signKey "admin" RotateAdminAction args
  RotateArbiter args -> runRotation txBuildingCtx signKey "arbiter" RotateArbiterAction args
  SubmitTx args -> do
    -- Stripped for the same reason `sign-tx` strips its stdin: a human will have produced these
    -- files with a shell redirect, and a trailing newline is not part of the hex.
    let readHexFile what path parse = do
          hex <- T.unpack . T.strip <$> T.readFile path
          maybe (die ("submit-tx: " <> path <> " is not " <> what <> ".")) return (parse hex)
    tx <- readHexFile "a transaction's CBOR hex, as --build-only prints it" (staTxFile args) txFromHex
    witnesses <- mapM (\p -> readHexFile "a witness hex, as sign-tx prints it" p txWitFromHex) (staWitnessFiles args)
    printYellow $ "Submitting with " <> show (length witnesses) <> " collected witness(es) plus this key's ..."
    txId <- submitSignedTxWithWitnesses (providerCtx txBuildingCtx) signKey tx witnesses
    printGreen $ "Submitted and confirmed! TxId: " <> show txId
  -- Query oracle — read-only, does not go through the Interaction pipeline
  QueryOracle -> do
    printYellow "Querying oracle parameters..."
    let pCtx = providerCtx txBuildingCtx
        dCtx = deployedScriptsCtx txBuildingCtx
    (oracleParams, oracleRef, oracleVal) <- runQuery pCtx $ runReaderT queryOracleParams dCtx
    printGreen "=== Oracle Parameters ==="
    printGreen $ "  UTxO Ref:           " <> show oracleRef
    printGreen $ "  Value:              " <> show oracleVal
    printGreen $ "  Admin:              " <> show (opAdmin oracleParams)
    -- Printed even when it equals the admin, which at genesis it does. "Same as admin" is a fact an
    -- operator needs stated, not inferred from an absent line — the whole point of the split is
    -- that these two CAN differ, so a reader must be able to see that they currently do not.
    let arbiterNote
          | opArbiter oracleParams == opAdmin oracleParams = "   (same as admin — not split)"
          | otherwise = "   (SPLIT from admin)"
    printGreen $ "  Arbiter:            " <> show (opArbiter oracleParams) <> arbiterNote
    printGreen $ "  Paused:             " <> show (opPaused oracleParams)
    printGreen $ "  Min UTxO Value:     " <> show (opMinUTxOValue oracleParams) <> " lovelace"
    printGreen $ "  Dispute Deposit:    " <> show (opDisputeDeposit oracleParams) <> " lovelace"
    -- The field `set-dispute-timeout` writes, which this command did not read back. An admin command
    -- that can change a value but cannot show it leaves the operator guessing at the one number that
    -- decides when a dispute becomes closable by anyone, and the first deploy is exactly when you
    -- want to confirm the genesis value rather than infer it from the source you hope was built.
    printGreen $
      "  Dispute Timeout:    "
        <> show (opDisputeTimeoutMs oracleParams)
        <> " ms ("
        <> show (opDisputeTimeoutMs oracleParams `div` 86_400_000)
        <> " days)"
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

-- | Both handovers, which differ only in which field of the oracle datum moves.
--
-- __Why this cannot be one command.__ @O5@ requires the INCOMING side to prove control in the same
-- transaction that the outgoing admin authorises, and this process holds one key. So a single
-- build-sign-submit produces a transaction the chain refuses by construction — which is precisely
-- what @rotate-admin@ did before, and the audit's @OF-01@: the command that exists to rotate the
-- admin could not rotate the admin. The flagless form therefore refuses and names the two commands
-- that finish the job, rather than submitting something doomed and reporting a script failure.
--
-- The refusal is the feature. An error that says what to do next costs one message; a confirmed
-- transaction that turns out to be unsubmittable costs a fee and an investigation.
runRotation ::
  TxBuildingContext ->
  GYExtendedPaymentSigningKey ->
  -- | Which power is moving, for the messages: @"admin"@ or @"arbiter"@.
  String ->
  (Credential -> Maybe ClaimWitness -> AdminActionType) ->
  RotateArgs ->
  IO ()
runRotation txBuildingCtx signKey what mkAction args = do
  -- Not `action`: optparse-applicative exports one, and shadowing it inside the command that
  -- builds an action reads fine and means something else.
  let rotation = AdminAction (mkAction (rotCredential args) (rotIncomingWitness args)) (rotAdminWitness args)
  if rotBuildOnly args
    then do
      printYellow $ "Building the " <> what <> " handover to " <> show (rotCredential args) <> " ..."
      txHex <- buildActionWithPK txBuildingCtx signKey rotation
      printYellow "Unsigned transaction hex follows. It is NOT submitted and NOT signed."
      putStrLn txHex
      printYellow $
        "Next, and both are required:\n\
        \  1. the INCOMING side proves control (O5). A key signs it:\n\
        \       printf '%s' <hex> | cabal run -v0 exe:admin -- sign-tx > incoming.wit\n\
        \     A native multisig instead proves control by SPENDING, so it must already hold a UTxO\n\
        \     at its own address and the build above must have been given --incoming-witness.\n\
        \  2. you submit, which also adds this key's signature (O1):\n\
        \       cabal run exe:admin -- submit-tx --tx tx.hex --witness incoming.wit"
    else
      die $
        "rotate-"
          <> what
          <> ": refused, because this would build a transaction the chain rejects.\n\
             \O5 requires the INCOMING credential to prove control in the same transaction, and this\n\
             \process holds only the key in operation.prv. Run it in two steps:\n\
             \  cabal run -v0 exe:admin -- rotate-"
          <> what
          <> " --new-credential <hash> [--script] --build-only > tx.hex\n\
             \then have the incoming side witness tx.hex, then submit-tx --tx tx.hex --witness <file>."

-- | The startup banner.
--
-- It goes to stdout, and @sign-tx@'s stdout __is__ its product — the smoke script captures that
-- stream whole (@wit=$(… | $signer)@), so one decorative line there is a witness set that does not
-- parse. That is why the banner is printed after the parse rather than as @main@'s first act: before
-- the parse there is no command to exempt.
banner :: Command -> IO ()
banner (SignTx _) = pure ()
banner _ = printGreen "Palmares - Cardano governance track record"

main :: IO ()
main = do
  -- Parse command line arguments
  cmd <-
    execParser $
      info
        (commandParser <**> helper)
        ( fullDesc
            <> progDesc "A command-line tool for the Palmares attestation protocol on Cardano. Deploys reference scripts, writes the CIP-57 blueprint, administers the oracle, and issues or accepts attestations."
            <> header "Palmares - Cardano governance track record"
        )

  banner cmd

  -- Handle commands that don't require blockchain providers
  case cmd of
    WriteBlueprint outputPath -> do
      printYellow $ "Writing CIP-57 contract blueprint to " <> outputPath <> " ..."
      B.writeFile outputPath (encodePretty $ contractBlueprint blueprintProtocolParams)
      printGreen $ "Blueprint written successfully to " <> outputPath
    -- No provider, no signing key, no deployed-validators config, which is what would let CI run
    -- this command to check a committed document for drift.
    --
    -- THERE IS NO SUCH CHECK AND NO COMMITTED DOCUMENT. `docs/generated/` holds only `.gitkeep`
    -- and `swagger/`, git has no history for the blueprint path, and no workflow runs
    -- `write-blueprint`. The sentence above described an intention; this one describes the repo.
    -- The two Swagger documents ARE gated that way (`cabal run -v0 exe:query-api --
    -- --write-swagger-only` then `git diff --exit-code`), so the pattern exists and the blueprint
    -- is simply not in it yet.
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
    -- No provider and no deployed-validators config: these two exist to be runnable BEFORE anything
    -- is deployed, which is the whole point of them. `new-operator-key` does not even read a key.
    NewOperatorKey -> newOperatorKey
    OperatorAddress -> operatorAddress
    -- Same family: signing is a function of the transaction and the key, so no provider, no
    -- validator config and no network. That is what lets the smoke script invoke this once per
    -- write with nothing but `operation.prv` beside it.
    SignTx mKeyFile -> signTxWitness (fromMaybe mnemonicFilePath mKeyFile)
    _ -> executeOnchainCommand cmd

-- | Generate a fresh operator mnemonic into 'mnemonicFilePath' and print the address to fund.
--
-- __Why this command exists.__ @readMnemonicFile@ expects a 24-word BIP-39 phrase and nothing in this
-- repository could produce one, so "use a new dedicated key" was a decision with no way to carry it
-- out. The alternative was a mnemonic from some external generator plus an address derived by some
-- other tool — and if those two disagree, the deploy fails with "no UTxOs" at a funded address,
-- which is the least diagnosable failure available. The derivation here is the SAME code the deploy
-- will use (@walletKeysFromMnemonic@ via 'readMnemonic'), so the printed address is the address that
-- will be spent from, by construction rather than by coincidence.
--
-- __The entropy is the system CSPRNG__, via @cardano-addresses@' own 'genEntropy', and the phrase is
-- checksummed by 'entropyToMnemonic'. 256 bits is 24 words. Nothing here hand-rolls BIP-39, and the
-- generated phrase is read back through 'readMnemonic' before the file is accepted — so a phrase
-- this command cannot itself load never reaches the disk as the live key.
--
-- __It refuses to overwrite.__ An operator key that is silently replaced is an oracle nobody
-- controls: @O1@ then refuses every update, including the rotation that would fix it. The file is
-- written 0600, and the phrase is never printed — the file is the only copy, which is also what makes
-- "disposable" an honest word for it.
newOperatorKey :: IO ()
newOperatorKey = do
  exists <- doesFileExist mnemonicFilePath
  when exists $
    die
      ( mnemonicFilePath
          <> " already exists and will NOT be overwritten. Move it aside first if you really mean to\n\
             \replace the operator key; `operator-address` prints the address of the current one."
      )
  entropy <- Mnemonic.genEntropy @256
  let phrase = T.unwords (Mnemonic.mnemonicToText (Mnemonic.entropyToMnemonic entropy))
  -- Read back through the project's own loader BEFORE writing: a phrase that this binary cannot
  -- load is not a key, and finding that out at deploy time would be finding it out too late.
  signKey <- readMnemonic phrase
  T.writeFile mnemonicFilePath phrase
  setFileMode mnemonicFilePath 0o600
  printGreen ("Wrote a new 24-word operator mnemonic to " <> mnemonicFilePath <> " (mode 0600)")
  printYellow "The phrase is NOT printed. That file is the only copy."
  printOperatorAddress signKey

-- | Print the address derived from the existing 'mnemonicFilePath'.
--
-- The step between generating the key and deploying: this is the address that has to hold funds
-- before @deploy-reference-scripts@ can pay for five reference-script outputs and the oracle.
operatorAddress :: IO ()
operatorAddress = readMnemonicFile mnemonicFilePath >>= printOperatorAddress

-- | Render what an operator key identifies: its address, and its DRep credential.
--
-- __The network comes from the Atlas config, not from a flag.__ An address is network-specific, and
-- a flag would let someone fund a @preprod@ address while the deploy runs against @mainnet@ — the
-- same class of mistake as deriving the address with a different tool. One source for the network
-- means the printed address cannot belong to a different chain than the deploy.
printOperatorAddress :: GYExtendedPaymentSigningKey -> IO ()
printOperatorAddress signKey = do
  let pkh = extendedVerificationKeyHash (getExtendedVerificationKey signKey)
  -- THE THIRD CONSUMER OF THE SAME KEY, and the reason it is printed rather than put behind a flag:
  -- `scripts/smoke_attest_flow.sh` requires ATTEST_SMOKE_DREP_ID to be the DRep credential of the
  -- key PALMARES_SIGN_CMD signs with, because claiming a key credential puts
  -- `mustBeSignedBy <that key hash>` in the transaction (TxBuilding/Operations.hs
  -- `claimProofSkeleton`). Nothing printed it, so the flow's configuration could only be assembled
  -- by slicing the hash out of the address hex — deriving it with a second tool, which is the
  -- mistake this function's network argument exists to prevent.
  --
  -- Rendered with `claimCredentialToText`, the SAME function the read path renders a claimed
  -- credential with, so this id and the one `/profiles/by-credential/…` answers to are one
  -- encoding rather than two.
  --
  -- PRINTED BEFORE THE CONFIG IS LOADED, because a CIP-129 credential carries no network byte and
  -- this value does not depend on one. The Atlas config is this project's currently BLOCKED item,
  -- and the DRep id is the one thing a reader needs from this command while blocked on it — so
  -- printing it after the `die` below put it out of reach of exactly the people who needed it. The
  -- order reads correctly on its own terms too: network-independent first, then the network, then
  -- the two forms that depend on it.
  --
  -- WHAT THIS IS NOT: a claim that this DRep is registered on chain. It is the credential this key
  -- controls, which is all the registry checks. A production wallet derives its DRep key at CIP-1852
  -- role 3, so a real DRep's id will NOT equal its payment key hash — these coincide only because
  -- the operator mnemonic yields one key and the smoke flow signs with that one.
  printGreen
    ( "Operator DRep id (CIP-129, for ATTEST_SMOKE_DREP_ID): "
        <> T.unpack (claimCredentialToText (ClaimedDRep (PubKeyCredential (paymentKeyHashToPlutus pkh))))
    )
  atlasConfig <-
    maybe
      (die ("Atlas configuration not found — set ATLAS_CORE_CONFIG or create " <> Constants.defaultAtlasCoreConfig))
      return
      =<< decodeConfigEnvOrFile "ATLAS_CORE_CONFIG" Constants.defaultAtlasCoreConfig
  let nid = cfgNetworkId atlasConfig
      addr = addressFromPaymentKeyHash nid pkh
  printYellow ("Network: " <> show nid)
  printGreen ("Operator address (bech32): " <> T.unpack (addressToText addr))
  -- BOTH FORMS, because the two consumers want different ones and neither accepts the other's.
  -- A human funds the bech32 form from a wallet. Every HTTP request field typed `GYAddress` wants
  -- RAW CBOR HEX: `FromJSON GYAddress` delegates to `FromHttpApiData`, which is
  -- `deserialiseFromRawBytesHex`, and bech32 is refused there — `GYAddressBech32` is the bech32
  -- type and no request field uses it. The generated Swagger's prose for `GYAddress` says
  -- "Bech32-encoded Cardano address", which is wrong; its own `format: cbor hex` and hex example
  -- are right. Printing only bech32 here would have handed the smoke script a value it cannot use.
  -- `Web.toUrlPiece` is the SAME instance the API parses with, so these two can never disagree.
  printGreen ("Operator address (raw hex, for API request fields): " <> T.unpack (Web.toUrlPiece addr))

-- | Read an unsigned transaction's CBOR hex on stdin; write its witness set's hex on stdout.
--
-- The body is recovered with the SAME 'getTxBody' the interaction API applies to @tx_unsigned@, from
-- the same bytes, so the body signed here and the body the witness is attached to there cannot
-- differ. Whether the key is one the transaction actually requires is not checked and cannot be: a
-- claim names its own credential and the node is what refuses a transaction that lacks a signature.
signTxWitness :: FilePath -> IO ()
signTxWitness keyFile = do
  -- NOT 'readMnemonicFile': that announces the path on stdout, and stdout is this command's product.
  -- Same derivation — 'readMnemonic' is what @new-operator-key@ validates with.
  signKey <- readMnemonic =<< T.readFile keyFile
  -- Stripped because a human will pipe `echo`'s newline in; the smoke script uses `printf '%s'`.
  input <- T.unpack . T.strip <$> T.getContents
  tx <-
    maybe
      ( die
          "sign-tx: stdin is not a transaction's CBOR hex. It wants exactly what a write route\n\
          \returned — the contents of that JSON string, unquoted, with no envelope around it."
      )
      return
      (txFromHex input)
  T.putStrLn . txWitToHex . keyWitnessesOf $ signGYTxBody (getTxBody tx) [signKey]

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
