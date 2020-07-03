{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Benchmark measuring how long restoration takes for different wallets.
--
-- Easiest run using
-- @
--     $ export NODE_DB="node-db-testnet"
--     $ nix-build -A benchmarks.cardano-wallet-byron.restore -o restore && ./restore/bin/restore --testnet
-- @
--
-- or
-- @
--     $ ./.buildkite/bench-restore.sh byron testnet
-- @
--
-- since it relies on lots of configuration most most easily retrieved with nix.

module Main where

import Prelude

import Cardano.BM.Configuration.Static
    ( defaultConfigStdout )
import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Setup
    ( setupTrace_ )
import Cardano.BM.Trace
    ( Trace, nullTracer )
import Cardano.DB.Sqlite
    ( destroyDBLayer, unsafeRunQuery )
import Cardano.Launcher
    ( Command (..), StdStream (..), withBackendProcess )
import Cardano.Mnemonic
    ( SomeMnemonic (..) )
import Cardano.Startup
    ( installSignalHandlers )
import Cardano.Wallet
    ( WalletLayer (..), WalletLog (..) )
import Cardano.Wallet.Byron
    ( SomeNetworkDiscriminant (..) )
import Cardano.Wallet.Byron.Compatibility
    ( Byron
    , NodeVersionData
    , emptyGenesis
    , fromByronBlock
    , fromNetworkMagic
    , mainnetVersionData
    )
import Cardano.Wallet.Byron.Launch
    ( NetworkConfiguration (..), parseGenesisData )
import Cardano.Wallet.Byron.Network
    ( withNetworkLayer )
import Cardano.Wallet.Byron.Transaction
    ( newTransactionLayer )
import Cardano.Wallet.Byron.Transaction.Size
    ( MaxSizeOf (..) )
import Cardano.Wallet.DB
    ( DBLayer )
import Cardano.Wallet.DB.Sqlite
    ( PersistState, newDBLayer )
import Cardano.Wallet.Logging
    ( trMessageText )
import Cardano.Wallet.Network
    ( FollowLog (..), NetworkLayer (..) )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Depth (..)
    , NetworkDiscriminant (..)
    , NetworkDiscriminantVal (..)
    , PersistPrivateKey
    , WalletKey
    , digest
    , publicKey
    )
import Cardano.Wallet.Primitive.AddressDerivation.Byron
    ( ByronKey )
import Cardano.Wallet.Primitive.AddressDerivation.Icarus
    ( IcarusKey )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( IsOurs, IsOwned )
import Cardano.Wallet.Primitive.AddressDiscovery.Any
    ( initAnyState )
import Cardano.Wallet.Primitive.AddressDiscovery.Any.TH
    ( migrateAll )
import Cardano.Wallet.Primitive.AddressDiscovery.Random
    ( RndState, mkRndState )
import Cardano.Wallet.Primitive.Model
    ( currentTip, totalUTxO )
import Cardano.Wallet.Primitive.Types
    ( Address
    , Block (..)
    , BlockHeader (..)
    , ChimericAccount
    , GenesisParameters (..)
    , NetworkParameters (..)
    , SlotId (..)
    , SyncProgress (..)
    , WalletId (..)
    , WalletName (..)
    , computeUtxoStatistics
    , log10
    , mkSyncTolerance
    , slotAt
    , slotParams
    , syncProgressRelativeToTime
    )
import Cardano.Wallet.Unsafe
    ( unsafeMkMnemonic, unsafeRunExceptT )
import Control.Concurrent
    ( forkIO, threadDelay )
import Control.DeepSeq
    ( NFData, rnf )
import Control.Exception
    ( bracket, evaluate, throwIO )
import Control.Monad
    ( forM, join, mapM_, void )
import Control.Monad.IO.Class
    ( MonadIO (..) )
import Control.Monad.Trans.Except
    ( runExceptT )
import Control.Tracer
    ( Tracer (..), traceWith )
import Criterion.Measurement
    ( getTime, initializeTime, secs )
import Data.Maybe
    ( fromMaybe )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Quantity (..) )
import Data.Text
    ( Text )
import Data.Time.Clock.POSIX
    ( getCurrentTime, utcTimeToPOSIXSeconds )
import Database.Persist.Sql
    ( runMigrationSilent )
import Fmt
    ( build, fmt, pretty, (+|), (+||), (|+), (||+) )
import Options.Applicative
    ( Parser, execParser, flag', info, long, (<|>) )
import Ouroboros.Network.NodeToClient
    ( NodeToClientVersionData (..) )
import Say
    ( sayErr )
import System.Environment
    ( getEnv )
import System.FilePath
    ( (</>) )
import System.IO
    ( BufferMode (..)
    , IOMode (..)
    , hFlush
    , hSetBuffering
    , stderr
    , stdout
    , withFile
    )
import System.IO.Temp
    ( createTempDirectory, getCanonicalTemporaryDirectory, withSystemTempFile )

import qualified Cardano.BM.Configuration.Model as CM
import qualified Cardano.BM.Data.BackendKind as CM
import qualified Cardano.Wallet as W
import qualified Cardano.Wallet.DB.Sqlite as Sqlite
import qualified Cardano.Wallet.Primitive.AddressDerivation.Byron as Byron
import qualified Data.ByteString.Char8 as B8
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

main :: IO ()
main = do
    (networkConfig, nodeConfig, cleanup) <- getNetworkConfiguration

    exec networkConfig nodeConfig `finally` cleanup

data Args = Args
    { networkName :: Maybe String
    , configsDir :: Maybe FilePath
    , nodeDatabaseDir :: Maybe FilePath
    } deriving (Show, Eq)

getNetworkConfiguration :: IO (NetworkConfiguration, CardanoNodeConfig, IO ())
getNetworkConfiguration = do
    let opts = info argsParser mempty
    args <- addEnvs =<< execParser opts

    configs <- maybe (die "--cardano-node-configs arg not set") pure (configsDir args)

    networkConfig <- case networkName args of
        Nothing ->
            die "NETWORK arg not set"
        Just "mainnet" ->
            pure $ MainnetConfig (SomeNetworkDiscriminant $ Proxy @'Mainnet, mainnetVersionData)
        Just networkName -> do
            let testnetGenesis = configs </> networkName </> "genesis.json"
            pure $ TestnetConfig testnetGenesis

    (dbDir, cleanup) <- case nodeDatabaseDir args of
        Nothing -> do
            -- Temporary directory for storing socket and node database
            tmpDir <- getCanonicalTemporaryDirectory
                >>= \tmpRoot -> createTempDirectory tmpRoot "cw-byron"
            pure (tmpDir, removeDirectoryRecursive tmpDir)
        Just d -> pure (d, pure ())

    let networkDir = configs </> networkName
    let nodeConfig = CardanoNodeConfig
            { nodeConfigFile   = networkDir </> "configuration.json"
            , nodeDatabaseDir  = dbDir
            , nodeDlgCertFile  = ""
            , nodeSignKeyFile  = ""
            , nodeSocketFile   = dbDir </> "cardano-node.socket"
            , nodeTopologyFile = networkDir </> "topology.json"
            }

    pure (networkConfig, nodeConfig, cleanup)

argsParser :: Parser Args
argsParser = Args
    <$> strArgument (metavar "NETWORK" <> help "Blockchain to use. Defaults to $NETWORK.")
    <*> strOption
        ( long "cardano-node-configs"
          <> short 'c'
          <> metavar "DIR"
          <> help "Directory containing configurations for each network. Defaults to $CARDANO_NODE_CONFIGS")
    <*> strOption
        ( long "node-db"
          <> metavar "DB"
          <> help "Directory to put cardano-node state. Defaults to $NODE_DB, falls back to temporary directory")

cardanoNodeCommand :: CardanoNodeConfig -> Int -> Command
cardanoNodeCommand cfg port = Command "cardano-node" args (return ()) Inherit Inherit
  where
    args =
        [ "run"
        , "--database-path", nodeDatabaseDir cfg
        , "--topology", nodeTopologyFile cfg
        , "--socket-path", nodeSocketPath cfg
        , "--config", nodeConfigFile cfg
        , "--port", show port
        ]


-- Environment variables set by nix/haskell.nix (or manually)
-- Environment variables set by ./buildkite/bench-restore.sh (or manually)
addEnvs :: Args -> IO Args
addEnvs (Args n c d) = update
    <$> lookupEnv' "NETWORK"
    <*> lookupEnv' "CARDANO_NODE_CONFIGS"
    <*> lookupEnv' "NODE_DB"
  where
    update ne ce de = Args (n <|> ne) (c <|> ce) (d <|> de)
    lookupEnv' k = lookupEnv k <&> \case
        Just "" -> Nothing
        Just v -> Just v
        Nothing -> Nothing

-- | Run all available benchmarks. Can accept one argument that is a target
-- network against which benchmarks below should be ran
exec :: NetworkConfiguration -> CardanoNodeConfig -> IO ()
exec c nodeConfig = do
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering

    (_logCfg, tr) <- initBenchmarkLogging Info
    installSignalHandlers (return ())

    (SomeNetworkDiscriminant networkProxy, np, vData, _b)
        <- unsafeRunExceptT $ parseGenesisData c

    let network = networkDescription networkProxy
    sayErr $ "Network: " <> network

    cmd <- cardanoNodeCommand nodeConfig <$> getRandomPort

    sayErr "Starting node with command:"
    sayErr $ pretty cmd

    void $ withBackendProcess nullTracer cmd $ do
            prepareNode networkProxy (nodeSocketFile nodeConfig) np vData
            runBenchmarks
                [ bench ("restore " <> network <> " seq")
                    (bench_restoration @_ @ByronKey
                        networkProxy
                        tr
                        (nodeSocketFile nodeConfig)
                        np
                        vData
                        "seq.timelog"
                        (walletRnd))

                , bench ("restore " <> network <> " 1% ownership")
                    (bench_restoration @_ @IcarusKey
                        networkProxy
                        tr
                        (nodeSocketFile nodeConfig)
                        np
                        vData
                        "1-percent.timelog"
                        (initAnyState "Benchmark 1% Wallet" 0.01))

                , bench ("restore " <> network <> " 2% ownership")
                    (bench_restoration @_ @IcarusKey
                        networkProxy
                        tr
                        (nodeSocketFile nodeConfig)
                        np
                        vData
                        "2-percent.timelog"
                        (initAnyState "Benchmark 2% Wallet" 0.02))
                ]
  where
    walletRnd
        :: (WalletId, WalletName, RndState n)
    walletRnd =
        let
            seed = SomeMnemonic . unsafeMkMnemonic @15 $ T.words
                "involve key curtain arrest fortune custom lens marine before \
                \material wheel glide cause weapon wrap"
            xprv = Byron.generateKeyFromSeed seed mempty
            wid = WalletId $ digest $ publicKey xprv
            wname = WalletName "Benchmark Sequential Wallet"
            rngSeed = 0
            s = mkRndState xprv rngSeed
        in
            (wid, wname, s)

    networkDescription :: forall n. (NetworkDiscriminantVal n) => Proxy n -> Text
    networkDescription _ = networkDiscriminantVal @n

runBenchmarks :: [IO (Text, Double)] -> IO ()
runBenchmarks bs = do
    initializeTime
    -- NOTE: Adding an artificial delay between successive runs to get a better
    -- output for the heap profiling.
    rs <- forM bs $ \io -> io <* let _2s = 2000000 in threadDelay _2s
    sayErr "\n\nAll results:"
    mapM_ (uncurry printResult) rs

bench :: Text -> IO () -> IO (Text, Double)
bench benchName action = do
    sayErr $ "Running " <> benchName
    start <- getTime
    res <- action
    evaluate (rnf res)
    finish <- getTime
    let dur = finish - start
    printResult benchName dur
    pure (benchName, dur)

printResult :: Text -> Double -> IO ()
printResult benchName dur = sayErr . fmt $ "  "+|benchName|+": "+|secs dur|+""

initBenchmarkLogging :: Severity -> IO (CM.Configuration, Trace IO Text)
initBenchmarkLogging minSeverity = do
    c <- defaultConfigStdout
    CM.setMinSeverity c minSeverity
    CM.setSetupBackends c [CM.KatipBK, CM.AggregationBK]
    (tr, _sb) <- setupTrace_ c "bench-restore"
    pure (c, tr)

{-------------------------------------------------------------------------------
                                  Benchmarks
-------------------------------------------------------------------------------}

{-# ANN bench_restoration ("HLint: ignore Use camelCase" :: String) #-}
bench_restoration
    :: forall (n :: NetworkDiscriminant) (k :: Depth -> * -> *) s t.
        ( IsOurs s Address
        , IsOurs s ChimericAccount
        , IsOwned s k
        , WalletKey k
        , NFData s
        , Show s
        , MaxSizeOf Address n ByronKey
        , PersistState s
        , PersistPrivateKey (k 'RootK)
        , NetworkDiscriminantVal n
        , t ~ IO Byron
        )
    => Proxy n
    -> Trace IO Text
    -> FilePath
       -- ^ Socket path
    -> NetworkParameters
    -> NodeVersionData
    -> FilePath
       -- ^ Log output
    -> (WalletId, WalletName, s)
    -> IO ()
bench_restoration _proxy tracer socketPath np vData progressLogFile (wid, wname, s) = do
    let networkText = networkDiscriminantVal @n
    let pm = fromNetworkMagic $ networkMagic $ fst vData
    let tl = newTransactionLayer @n @k @(IO Byron) (Proxy) pm
    withNetworkLayer nullTracer np socketPath vData $ \nw' -> do
        let gp = genesisParameters np
        let convert =
                fromByronBlock (getGenesisBlockHash gp) (getEpochLength gp)
        let nw = convert <$> nw'
        withBenchDBLayer @s @k tracer $ \db -> do
            BlockHeader sl _ _ _ <- unsafeRunExceptT $ currentNodeTip nw
            sayErr . fmt $ networkText ||+ " tip is at " +|| sl ||+ ""

            withFile progressLogFile WriteMode $ \h -> do
                -- Use a custom tracer to output (time, blockHeight) to a file
                -- each time we apply blocks.
                let fileTr = Tracer $ \msg -> do
                        liftIO . B8.hPut h . T.encodeUtf8 . (<> "\n") $ msg
                        hFlush h
                let w = WalletLayer
                        (traceProgressForPlotting fileTr)
                        (emptyGenesis gp, np, mkSyncTolerance 3600)
                        nw
                        tl
                        db
                wallet <- unsafeRunExceptT $ W.createWallet w wid wname s
                void $ forkIO $ unsafeRunExceptT $ W.restoreWallet @_ @s @t @k w wid
                waitForWalletSync w wallet gp vData
                (wallet', _, pending) <- unsafeRunExceptT $ W.readWallet w wid
                sayErr "Wallet restored!"
                sayErr . fmt . build $
                    computeUtxoStatistics log10 (totalUTxO pending wallet')
                unsafeRunExceptT $ W.deleteWallet w wid

traceProgressForPlotting :: Tracer IO Text -> Tracer IO WalletLog
traceProgressForPlotting tr = Tracer $ \case
    MsgFollow (MsgApplyBlocks bs) -> do
        let tip = pretty . getQuantity . blockHeight . NE.last $ bs
        time <- pretty . utcTimeToPOSIXSeconds <$> getCurrentTime
        traceWith tr (time <> " " <> tip)
    _ -> return ()

withBenchDBLayer
    :: forall s k a.
        ( IsOwned s k
        , NFData s
        , Show s
        , PersistState s
        , IsOurs s ChimericAccount
        , IsOurs s Address
        , PersistPrivateKey (k 'RootK)
        )
    => Trace IO Text
    -> (DBLayer IO s k -> IO a)
    -> IO a
withBenchDBLayer tr action =
    withSystemTempFile "bench.db" $ \dbFile _ -> do
        let before = newDBLayer (trMessageText tr) migrationDefaultValues (Just dbFile)
        let after = destroyDBLayer . fst
        bracket before after $ \(ctx, db) -> do
            migrateDB ctx
            action db
  where
    migrationDefaultValues = Sqlite.DefaultFieldValues
        { Sqlite.defaultActiveSlotCoefficient = 1
        }

    -- This tweaks the DB support the AnyAddressState.
    migrateDB ctx = unsafeRunQuery ctx (void $ runMigrationSilent migrateAll)


logChunk :: SlotId -> IO ()
logChunk slot = sayErr . fmt $ "Processing "+||slot||+""

prepareNode
    :: forall n. (NetworkDiscriminantVal n)
    => Proxy n
    -> FilePath
    -> NetworkParameters
    -> NodeVersionData
    -> IO ()
prepareNode _ socketPath np vData = do
    sayErr . fmt $ "Syncing "+|networkDiscriminantVal @n|+" node... "
    sl <- withNetworkLayer nullTracer np socketPath vData $ \nw' -> do
        let gp = genesisParameters np
        let convert =
                fromByronBlock (getGenesisBlockHash gp) (getEpochLength gp)
        let nw = convert <$> nw'
        waitForNodeSync nw logQuiet gp
    sayErr . fmt $ "Completed sync of "+|networkDiscriminantVal @n|+" up to "+||sl||+""

-- | Regularly poll the wallet to monitor it's syncing progress. Block until the
-- wallet reaches 100%.
waitForWalletSync
    :: forall s t k. ()
    => WalletLayer s t k
    -> WalletId
    -> GenesisParameters
    -> NodeVersionData
    -> IO ()
waitForWalletSync walletLayer wid gp vData = do
    (w, _, _) <- unsafeRunExceptT $ W.readWallet walletLayer wid
    let tol = mkSyncTolerance 3600
    prog <- syncProgressRelativeToTime
                tol
                (slotParams gp)
                (currentTip w)
                <$> getCurrentTime
    case prog of
        Ready -> return ()
        NotResponding -> do
            threadDelay 1000000
            waitForWalletSync walletLayer wid gp vData
        Syncing (Quantity p) -> do
            sayErr . fmt $ "[INFO] restoring: "+|p|+""
            threadDelay 1000000
            waitForWalletSync walletLayer wid gp vData

-- | Poll the network tip until it reaches the slot corresponding to the current
-- time.
waitForNodeSync
    :: NetworkLayer IO (IO Byron) Block
    -> (SlotId -> SlotId -> IO ())
    -> GenesisParameters
    -> IO SlotId
waitForNodeSync nw logSlot gp = loop 10
  where
    loop :: Int -> IO SlotId
    loop retries = runExceptT (currentNodeTip nw) >>= \case
        Right (BlockHeader tipBlockSlot _ _ _) -> do
            currentSlot <- getCurrentSlot
            logSlot tipBlockSlot currentSlot
            if tipBlockSlot < currentSlot
                then do
                    -- 2 seconds poll interval
                    threadDelay 2000000
                    loop retries
                else
                    pure tipBlockSlot
        Left e | retries > 0 -> do
                     sayErr "Fetching tip failed, retrying shortly..."
                     threadDelay 15000000
                     loop (retries - 1)
               | otherwise -> throwIO e

    getCurrentSlot :: IO SlotId
    getCurrentSlot = do
        let sp = slotParams gp
        fromMaybe (error errMsg) . slotAt sp <$> getCurrentTime
      where
        errMsg = "getCurrentSlot: is the current time earlier than the\
                 \start time of the blockchain"

logQuiet :: SlotId -> SlotId -> IO ()
logQuiet _ _ = pure ()
