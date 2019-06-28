{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: MIT
--
-- Shared types and helpers for CLI parsing

module Cardano.CLI
    (
    -- * Environment
      Environment (..)

    -- * CLI Construction
    , makeCli

    -- * Types
    , Port (..)

    -- * Logging
    , Verbosity (..)
    , initTracer
    , minSeverityFromArgs
    , verbosityFromArgs
    , verbosityToArgs

    -- * Mnemonics
    , execGenerateMnemonic

    -- * Unicode Terminal Helpers
    , setUtf8Encoding

    -- * ANSI Terminal Helpers
    , putErrLn
    , hPutErrLn

    -- * Parsing Arguments
    , OptionValue (..)
    , optional
    , parseArgWith
    , parseAllArgsWith
    , help

    -- * Working with Sensitive Data
    , getLine
    , hGetLine
    , getSensitiveLine
    , hGetSensitiveLine

    -- * Helpers
    , decodeError
    , showT
    ) where

import Prelude hiding
    ( getLine )

import Cardano.BM.Configuration.Model
    ( setMinSeverity )
import Cardano.BM.Configuration.Static
    ( defaultConfigStdout )
import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Setup
    ( setupTrace )
import Cardano.BM.Trace
    ( Trace, appendName )
import Cardano.Wallet.Primitive.Mnemonic
    ( entropyToMnemonic, genEntropy, mnemonicToText )
import Control.Arrow
    ( first )
import Control.Exception
    ( bracket )
import Control.Monad
    ( unless )
import Data.Aeson
    ( (.:) )
import Data.Bifunctor
    ( bimap )
import Data.Either
    ( fromRight )
import Data.Functor
    ( (<$) )
import Data.List
    ( sort )
import Data.Text
    ( Text )
import Data.Text.Class
    ( CaseStyle (..)
    , FromText (..)
    , TextDecodingError (..)
    , ToText (..)
    , fromTextToBoundedEnum
    , toTextFromBoundedEnum
    )
import Data.Text.Read
    ( decimal )
import Fmt
    ( Buildable, pretty )
import GHC.Generics
    ( Generic )
import GHC.TypeLits
    ( Symbol )
import System.Console.ANSI
    ( Color (..)
    , ColorIntensity (..)
    , ConsoleLayer (..)
    , SGR (..)
    , hCursorBackward
    , hSetSGR
    )
import System.Console.Docopt
    ( Arguments
    , Docopt
    , Option
    , exitWithUsageMessage
    , getAllArgs
    , getArgOrExitWith
    , isPresent
    , longOption
    , usage
    )
import System.Console.Docopt.NoTH
    ( parseUsage )
import System.Exit
    ( exitFailure, exitSuccess )
import System.IO
    ( BufferMode (..)
    , Handle
    , hGetBuffering
    , hGetChar
    , hGetEcho
    , hIsTerminalDevice
    , hPutChar
    , hSetBuffering
    , hSetEcho
    , hSetEncoding
    , stderr
    , stdin
    , stdout
    , utf8
    )
import Text.Heredoc
    ( here )

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

{-------------------------------------------------------------------------------
                                Environment
-------------------------------------------------------------------------------}

-- | A convenient representation of a complete CLI environment.
data Environment = Environment
    { args
        :: Arguments
    , cli
        :: Docopt
    , argPresent
        :: Option -> Bool
    , parseAllArgs
        :: forall a . FromText a => Option -> IO (NE.NonEmpty a)
    , parseArg
        :: forall a . FromText a => Option -> IO a
    , parseOptionalArg
        :: forall a . FromText a => Option -> IO (Maybe a)
    }

{-------------------------------------------------------------------------------
                              CLI Construction
-------------------------------------------------------------------------------}

-- | Make a specialized CLI from the specified commands, options, and examples.
--
makeCli :: String -> String -> String -> Docopt
makeCli cliCommandsSpecific cliOptionsSpecific cliExamplesSpecific =
    fromRight (error "Unable to construct CLI.") $
        parseUsage usageString
  where
    usageString = mempty
        <> cliHeader
        <> "\nUsage:\n"
        <> cliCommands
        <> "\nOptions:\n"
        <> cliOptions
        <> "\nExamples:\n"
        <> cliExamples
    cliCommands = unlines $ filter (not . null) $ lines $ mempty
        <> cliCommandsSpecific
        <> cliCommandsGeneric
    cliOptions = unlines $ filter (not . null) $ sort $ lines $ mempty
        <> cliOptionsSpecific
        <> cliOptionsGeneric
    cliExamples = unlines $ filter (not . null) $ lines $ mempty
        <> cliExamplesSpecific
        <> cliExamplesGeneric

cliHeader :: String
cliHeader = [here|Cardano Wallet CLI.

The CLI is a proxy to the wallet server, which is required for most
commands. Commands are turned into corresponding API calls, and submitted
to an up-and-running server. Some commands do not require an active server
and can be run "offline". (e.g. 'generate mnemonic')

    ⚠️  Options are positional (--a --b is not equivalent to --b --a) ! ⚠️
|]

cliCommandsGeneric :: String
cliCommandsGeneric = [here|
  cardano-wallet mnemonic generate [--size=INT]
  cardano-wallet wallet list [--port=INT]
  cardano-wallet wallet create [--port=INT] <name> [--address-pool-gap=INT]
  cardano-wallet wallet get [--port=INT] <wallet-id>
  cardano-wallet wallet update [--port=INT] <wallet-id> --name=STRING
  cardano-wallet wallet delete [--port=INT] <wallet-id>
  cardano-wallet transaction create [--port=INT] <wallet-id> --payment=PAYMENT...
  cardano-wallet address list [--port=INT] [--state=STRING] <wallet-id>
  cardano-wallet -h | --help
  cardano-wallet --version
|]

cliOptionsGeneric :: String
cliOptionsGeneric = [here|
  --address-pool-gap <INT>  number of unused consecutive addresses to keep track of [default: 20]
  --database <FILE>         use this file for storing wallet state
  --network <STRING>        testnet or mainnet [default: testnet]
  --payment <PAYMENT>       address to send to and amount to send separated by @: '<amount>@<address>'
  --port <INT>              port used for serving the wallet API [default: 8090]
  --quiet                   suppress all log output apart from errors
  --random-port             serve wallet API on any available port (conflicts with --port)
  --size <INT>              number of mnemonic words to generate [default: 15]
  --state <STRING>          address state: either used or unused
  --state-dir <DIR>         write wallet state (blockchain and database) to this directory
  --verbose                 display debugging information in the log output
|]

cliExamplesGeneric :: String
cliExamplesGeneric = [here|
  # Create a transaction and send 22 lovelace from wallet-id to specified address
  cardano-wallet transaction create 2512a00e9653fe49a44a5886202e24d77eeb998f \
    --payment 22@Ae2tdPwUPEZ...nRtbfw6EHRv1D
|]

{-------------------------------------------------------------------------------
                                Extra Types
-------------------------------------------------------------------------------}

-- | Port number with a tag for describing what it is used for
newtype Port (tag :: Symbol) = Port { getPort :: Int }
    deriving stock (Eq, Show, Generic)
    deriving newtype (Enum, Ord)

-- NOTE
-- TCP port ranges from [[-1;65535]] \ {0}
-- However, ports in [[-1; 1023]] \ {0} are well-known ports reserved
-- and only "bindable" through root privileges.
--
-- Ports above 49151 are also reserved for ephemeral connections. This
-- leaves us with a valid range of [[1024;49151]] for TCP ports.
instance Bounded (Port tag) where
    minBound = Port 1024
    maxBound = Port 49151

instance FromText (Port tag) where
    fromText t = do
        (p, unconsumed) <- bimap (const err) (first Port) (decimal t)
        unless (T.null unconsumed && p >= minBound && p <= maxBound) $ Left err
        return p
      where
        err = TextDecodingError
            $ "expected a TCP port number between "
            <> show (getPort minBound)
            <> " and "
            <> show (getPort maxBound)

instance ToText (Port tag) where
    toText (Port p) = toText p

instance FromText (OptionValue Severity) where
    fromText = fmap OptionValue . fromTextToBoundedEnum KebabLowerCase

instance ToText (OptionValue Severity) where
    toText = toTextFromBoundedEnum KebabLowerCase . getOptionValue

{-------------------------------------------------------------------------------
                             Parsing Arguments
-------------------------------------------------------------------------------}

-- | A wrapper to avoid orphan instances for types defined externally.
newtype OptionValue a = OptionValue { getOptionValue :: a }
  deriving (Enum, Eq, Ord, Generic, Read, Show)

-- | Make an existing parser optional. Returns 'Right Nothing' if the input is
-- empty, without running the parser.
optional
    :: (Monoid m, Eq m)
    => (m -> Either e a)
    -> (m -> Either e (Maybe a))
optional parse = \case
    m | m == mempty -> Right Nothing
    m  -> Just <$> parse m

parseArgWith :: FromText a => Docopt -> Arguments -> Option -> IO a
parseArgWith docopt arguments option = do
    (fromText . T.pack <$> arguments `getArgOrExit` option) >>= \case
        Right a -> return a
        Left e -> do
            putErrLn $ T.pack $ getTextDecodingError e
            exitFailure
  where
    getArgOrExit :: Arguments -> Option -> IO String
    getArgOrExit = getArgOrExitWith docopt

parseAllArgsWith
    :: FromText a => Docopt -> Arguments -> Option -> IO (NE.NonEmpty a)
parseAllArgsWith docopt arguments option = do
    (mapM (fromText . T.pack) <$> arguments `getAllArgsOrExit` option) >>= \case
        Right a -> return a
        Left e -> do
            putErrLn $ T.pack $ getTextDecodingError e
            exitFailure
  where
    getAllArgsOrExit :: Arguments -> Option -> IO (NE.NonEmpty String)
    getAllArgsOrExit = getAllArgsOrExitWith docopt

-- | Same as 'getAllArgs', but 'exitWithUsage' if empty list.
--
--   As in 'getAllArgs', if your usage pattern required the option,
--   'getAllArgsOrExitWith' will not exit.
getAllArgsOrExitWith :: Docopt -> Arguments -> Option -> IO (NE.NonEmpty String)
getAllArgsOrExitWith doc arguments opt =
    maybe err pure . NE.nonEmpty $ getAllArgs arguments opt
  where
    err = exitWithUsageMessage doc $ "argument expected for: " ++ show opt

-- | Like 'exitWithUsage', but with a success exit code
help :: Docopt -> IO ()
help docopt = do
    TIO.putStrLn $ T.pack $ usage docopt
    exitSuccess

{-------------------------------------------------------------------------------
                                  Logging
-------------------------------------------------------------------------------}

-- | Controls how much information to include in log output.
data Verbosity
    = Default
        -- ^ The default level of verbosity.
    | Quiet
        -- ^ Include less information in the log output.
    | Verbose
        -- ^ Include more information in the log output.
    deriving (Eq, Show)

-- | Determine the minimum 'Severity' level from the specified command line
--   arguments.
minSeverityFromArgs :: Arguments -> Severity
minSeverityFromArgs = verbosityToMinSeverity . verbosityFromArgs

-- | Determine the desired 'Verbosity' level from the specified command line
--   arguments.
verbosityFromArgs :: Arguments -> Verbosity
verbosityFromArgs arguments
    | arguments `isPresent` longOption "quiet"   = Quiet
    | arguments `isPresent` longOption "verbose" = Verbose
    | otherwise = Default

-- | Convert a given 'Verbosity' level into a list of command line arguments
--   that can be passed through to a sub-process.
verbosityToArgs :: Verbosity -> [String]
verbosityToArgs = \case
    Default -> []
    Quiet   -> ["--quiet"]
    Verbose -> ["--verbose"]

-- | Map a given 'Verbosity' level onto a 'Severity' level.
verbosityToMinSeverity :: Verbosity -> Severity
verbosityToMinSeverity = \case
    Default -> Info
    Quiet   -> Error
    Verbose -> Debug

-- | Initialize logging at the specified minimum 'Severity' level.
initTracer :: Severity -> Text -> IO (Trace IO Text)
initTracer minSeverity cmd = do
    c <- defaultConfigStdout
    setMinSeverity c minSeverity
    setupTrace (Right c) "cardano-wallet" >>= appendName cmd

{-------------------------------------------------------------------------------
                                 Mnemonics
-------------------------------------------------------------------------------}

-- | Generate a random mnemonic of the given size 'n' (n = number of words),
-- and print it to stdout.
execGenerateMnemonic :: Text -> IO ()
execGenerateMnemonic n = do
    m <- case n of
        "9"  -> mnemonicToText @9 . entropyToMnemonic <$> genEntropy
        "12" -> mnemonicToText @12 . entropyToMnemonic <$> genEntropy
        "15" -> mnemonicToText @15 . entropyToMnemonic <$> genEntropy
        "18" -> mnemonicToText @18 . entropyToMnemonic <$> genEntropy
        "21" -> mnemonicToText @21 . entropyToMnemonic <$> genEntropy
        "24" -> mnemonicToText @24 . entropyToMnemonic <$> genEntropy
        _  -> do
            putErrLn "Invalid mnemonic size. Expected one of: 9,12,15,18,21,24"
            exitFailure
    TIO.putStrLn $ T.unwords m

{-------------------------------------------------------------------------------
                            Unicode Terminal Helpers
-------------------------------------------------------------------------------}

-- | Override the system output encoding setting. This is needed because the CLI
-- prints UTF-8 characters regardless of the @LANG@ environment variable.
setUtf8Encoding :: IO ()
setUtf8Encoding = do
    hSetEncoding stdout utf8
    hSetEncoding stderr utf8

{-------------------------------------------------------------------------------
                            ANSI Terminal Helpers
-------------------------------------------------------------------------------}

-- | Print an error message in red
hPutErrLn :: Handle -> Text -> IO ()
hPutErrLn h msg = withSGR h (SetColor Foreground Vivid Red) $ do
    TIO.hPutStrLn h msg

-- | Like 'hPutErrLn' but with provided default 'Handle'
putErrLn :: Text -> IO ()
putErrLn = hPutErrLn stderr

{-------------------------------------------------------------------------------
                         Processing of Sensitive Data
-------------------------------------------------------------------------------}

-- | Prompt user and parse the input. Re-prompt on invalid inputs.
hGetLine
    :: Buildable e
    => (Handle, Handle)
    -> Text
    -> (Text -> Either e a)
    -> IO (a, Text)
hGetLine (hstdin, hstderr) prompt fromT = do
    TIO.hPutStr hstderr prompt
    txt <- TIO.hGetLine hstdin
    case fromT txt of
        Right a ->
            return (a, txt)
        Left e -> do
            hPutErrLn hstderr (pretty e)
            hGetLine (hstdin, hstderr) prompt fromT

-- | Like 'hGetLine' but with default handles
getLine
    :: Buildable e
    => Text
    -> (Text -> Either e a)
    -> IO (a, Text)
getLine = hGetLine (stdin, stderr)

-- | Gather user inputs until a newline is met, hiding what's typed with a
-- placeholder character.
hGetSensitiveLine
    :: Buildable e
    => (Handle, Handle)
    -> Text
    -> (Text -> Either e a)
    -> IO (a, Text)
hGetSensitiveLine (hstdin, hstderr) prompt fromT =
    withBuffering hstderr NoBuffering $
    withBuffering hstdin NoBuffering $
    withEcho hstdin False $ do
        TIO.hPutStr hstderr prompt
        txt <- getLineProtected '*'
        case fromT txt of
            Right a ->
                return (a, txt)
            Left e -> do
                hPutErrLn hstderr (pretty e)
                hGetSensitiveLine (hstdin, hstderr) prompt fromT
  where
    getLineProtected :: Char -> IO Text
    getLineProtected placeholder =
        getLineProtected' mempty
      where
        backspace = toEnum 127
        getLineProtected' line = do
            hGetChar hstdin >>= \case
                '\n' -> do
                    hPutChar hstderr '\n'
                    return line
                c | c == backspace ->
                    if T.null line
                        then getLineProtected' line
                        else do
                            hCursorBackward hstderr  1
                            hPutChar hstderr ' '
                            hCursorBackward hstderr 1
                            getLineProtected' (T.init line)
                c -> do
                    hPutChar hstderr placeholder
                    getLineProtected' (line <> T.singleton c)

-- | Like 'hGetSensitiveLine' but with default handles
getSensitiveLine
    :: Buildable e
    => Text
    -- ^ A message to prompt the user
    -> (Text -> Either e a)
    -- ^ An explicit parser from 'Text'
    -> IO (a, Text)
getSensitiveLine = hGetSensitiveLine (stdin, stderr)

{-------------------------------------------------------------------------------
                                Internals
-------------------------------------------------------------------------------}

withBuffering :: Handle -> BufferMode -> IO a -> IO a
withBuffering h buffering action = bracket aFirst aLast aBetween
  where
    aFirst = (hGetBuffering h <* hSetBuffering h buffering)
    aLast = hSetBuffering h
    aBetween = const action

withEcho :: Handle -> Bool -> IO a -> IO a
withEcho h echo action = bracket aFirst aLast aBetween
  where
    aFirst = (hGetEcho h <* hSetEcho h echo)
    aLast = hSetEcho h
    aBetween = const action

withSGR :: Handle -> SGR -> IO a -> IO a
withSGR h sgr action = hIsTerminalDevice h >>= \case
    True -> bracket aFirst aLast aBetween
    False -> action
  where
    aFirst = ([] <$ hSetSGR h [sgr])
    aLast = hSetSGR h
    aBetween = const action

{-------------------------------------------------------------------------------
                                 Helpers
-------------------------------------------------------------------------------}

-- | Decode API error messages and extract the corresponding message.
decodeError
    :: BL.ByteString
    -> Maybe Text
decodeError bytes = do
    obj <- Aeson.decode bytes
    Aeson.parseMaybe (Aeson.withObject "Error" (.: "message")) obj

-- | Show a data-type through its 'ToText' instance
showT :: ToText a => a -> String
showT = T.unpack . toText

