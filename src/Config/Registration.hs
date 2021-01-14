{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Handles configuration, which involves parsing command line
-- arguments and reading key files.

module Config.Registration (Config(Config), ConfigError, opts, mkConfig, Opts(Opts), parseOpts) where

import           Control.Exception.Safe (try)
import           Control.Lens (( # ))
import           Control.Lens.TH
import           Control.Monad.Except (ExceptT, MonadError, catchError, throwError)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import           Options.Applicative

import           Cardano.API (Address, AddressAny, Bech32DecodeError, FileError, NetworkId,
                     PaymentKey, SigningKey, StakeKey, Witness)
import qualified Cardano.API as Api
import           Cardano.Api.Typed (Shelley, SlotNo (SlotNo), TextEnvelopeError)
import           Cardano.CLI.Environment (EnvSocketError, readEnvSocketPath)
import           Cardano.CLI.Shelley.Commands (WitnessFile (WitnessFile))
import           Cardano.CLI.Shelley.Key (InputDecodeError)
import           Cardano.CLI.Types (SigningKeyFile (..), SocketPath)
import           Cardano.CLI.Voting.Signing (VotePaymentKey, VoteSigningKey, readVotePaymentKeyFile,
                     readVoteSigningKeyFile)

import           Cardano.API.Extended (AsBech32DecodeError (_Bech32DecodeError),
                     AsFileError (_FileIOError, __FileError),
                     AsInputDecodeError (_InputDecodeError), AsType (AsVotingKeyPublic),
                     VotingKeyPublic, deserialiseFromBech32', pNetworkId, parseAddressAny,
                     readSigningKeyFile, readerFromAttoParser)
import           Cardano.CLI.Voting.Error (AsTextEnvelopeError (_TextEnvelopeError))

data Config = Config
    { cfgPaymentAddress    :: AddressAny
    , cfgVoteSigningKey    :: VoteSigningKey
    , cfgPaymentSigningKey :: VotePaymentKey
    , cfgVotePublicKey     :: VotingKeyPublic
    , cfgNetworkId         :: NetworkId
    , cfgTTL               :: SlotNo
    , cfgOutFile           :: FilePath
    }
    deriving (Show)

data FileErrors = FileErrorInputDecode InputDecodeError
    | FileErrorTextEnvelope TextEnvelopeError
    deriving (Show)

makePrisms ''FileErrors

instance AsInputDecodeError FileErrors where
  _InputDecodeError = _FileErrorInputDecode

instance AsTextEnvelopeError FileErrors where
  _TextEnvelopeError = _FileErrorTextEnvelope

data ConfigError = ConfigFailedToReadFile (Api.FileError FileErrors)
    | ConfigFailedToDecodeBech32 Bech32DecodeError
    deriving (Show)

makePrisms ''ConfigError

instance AsFileError ConfigError FileErrors where
  __FileError = _ConfigFailedToReadFile

instance AsBech32DecodeError ConfigError where
  _Bech32DecodeError = _ConfigFailedToDecodeBech32

mkConfig
  :: Opts
  -> ExceptT ConfigError IO Config
mkConfig (Opts pskf addr vpkf sskf networkId ttl outFile) = do
  stkSign <- readVoteSigningKeyFile (SigningKeyFile sskf)
  paySign <- readVotePaymentKeyFile (SigningKeyFile pskf)
  votepk  <- readVotePublicKey vpkf

  pure $ Config addr stkSign paySign votepk networkId ttl outFile

data Opts = Opts
    { optPaymentSigningKeyFile :: FilePath
    , optPaymentAddress        :: AddressAny
    , optVotePublicKeyFile     :: FilePath
    , optStakeSigningKeyFile   :: FilePath
    , optNetworkId             :: NetworkId
    , optTTL                   :: SlotNo
    , optOutFile               :: FilePath
    }
    deriving (Eq, Show)

parseOpts :: Parser Opts
parseOpts = Opts
  <$> strOption (long "payment-signing-key" <> metavar "FILE" <> help "file used to sign transaction")
  <*> option (readerFromAttoParser parseAddressAny) (long "payment-address" <> metavar "STRING" <> help "address associated with payment (hard-coded to use info from first utxo of address)")
  <*> strOption (long "vote-public-key" <> metavar "FILE" <> help "vote key generated by jcli (corresponding private key must be ed25519extended)")
  <*> strOption (long "stake-signing-key" <> metavar "FILE" <> help "stake authorizing vote key")
  <*> pNetworkId
  <*> pTTL
  <*> strOption (long "out-file" <> metavar "FILE" <> help "File to output the signed transaction to")

opts =
  info
    ( parseOpts )
    ( fullDesc
    <> progDesc "Create a vote transaction"
    <> header "voter-registration - a tool to create vote transactions"
    )

pTTL :: Parser SlotNo
pTTL = SlotNo
    <$> option auto
          ( long "time-to-live"
          <> metavar "WORD64"
          <> help "The number of slots from the current slot at which the vote transaction times out."
          <> showDefault <> value 5000
          )

stripTrailingNewlines :: Text -> Text
stripTrailingNewlines = T.intercalate "\n" . filter (not . T.null) . T.lines

readVotePublicKey
  :: ( MonadIO m
     , MonadError e m
     , AsFileError e d
     , AsBech32DecodeError e
     )
  => FilePath
  -> m VotingKeyPublic
readVotePublicKey path = do
  result <- liftIO . try $ TIO.readFile path
  raw    <- either (\e -> throwError . (_FileIOError #) $ (path, e)) pure result
  let publicKeyBech32 = stripTrailingNewlines raw
  either (throwError . (_Bech32DecodeError #)) pure $ deserialiseFromBech32' AsVotingKeyPublic publicKeyBech32
