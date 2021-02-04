{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Cardano.API (ShelleyBasedEra (ShelleyBasedEraMary))
import           Cardano.Api.Protocol (Protocol (CardanoProtocol), withlocalNodeConnectInfo)
import           Cardano.Api.Typed (AsType (AsStakeAddress), Hash, Lovelace (Lovelace),
                     StakeCredential (StakeCredentialByKey), StakeKey, makeStakeAddress,
                     serialiseToBech32, serialiseToRawBytesHex)
import           Cardano.Chain.Slotting (EpochSlots (..))
import           Cardano.CLI.Types (QueryFilter (FilterByAddress), SocketPath (SocketPath))
import qualified Cardano.Crypto.DSIGN as Crypto
import           Control.Monad.Except (ExceptT, MonadError, runExceptT, throwError)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Logger (logInfoN, runNoLoggingT, runStderrLoggingT,
                     runStdoutLoggingT)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.Function ((&))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Options.Applicative as Opt

import           Cardano.API.Extended (readEnvSocketPath)
import           Cardano.CLI.Fetching (Fund, chunkFund, fundFromVotingFunds)
import           Cardano.CLI.Voting (createVoteRegistration, encodeVoteRegistration, prettyTx,
                     signTx)
import           Cardano.CLI.Voting.Error (AppError)
import           Cardano.CLI.Voting.Metadata (voteSignature)
import           Cardano.CLI.Voting.Signing (verificationKeyRawBytes)
import           Config
import qualified Config.Genesis as Genesis
import qualified Config.Registration as Register
import qualified Config.Rewards as Rewards
import           Genesis (decodeGenesisTemplateJSON, getBlockZeroDate, setBlockZeroDate,
                     setInitialFunds)

main :: IO ()
main = do
  regOpts <- Opt.execParser Register.opts
  eCfg    <- runExceptT (Register.mkConfig regOpts)
  case eCfg of
    Left (err :: Register.ConfigError) ->
      fail $ show err
    Right (Register.Config addr voteSign paySign votePub networkId ttl outFile) -> do
      eResult <- runExceptT $ do
        SocketPath sockPath <-  readEnvSocketPath
        withlocalNodeConnectInfo (CardanoProtocol $ EpochSlots 21600) networkId sockPath $ \connectInfo -> do
          -- Create a vote registration, encoding our registration
          -- as transaction metadata. The transaction sends some
          -- unspent ADA back to us (minus a fee).

          -- Generate vote payload (vote information is encoded as metadata).
          let vote = createVoteRegistration voteSign votePub addr

          -- Encode the vote as a transaction and sign it
          voteRegistrationTx <- signTx paySign <$> encodeVoteRegistration connectInfo ShelleyBasedEraMary addr ttl vote

          -- Output helpful information
          liftIO . putStrLn $ "Vote public key used        (hex): " <> BSC.unpack (serialiseToRawBytesHex votePub)
          liftIO . putStrLn $ "Stake public key used       (hex): " <> BSC.unpack (verificationKeyRawBytes voteSign)
          liftIO . putStrLn $ "Vote registration signature (hex): " <> BSC.unpack (Base16.encode . Crypto.rawSerialiseSigDSIGN $ voteSignature vote)

          -- Output our vote transaction
          liftIO . writeFile outFile $ prettyTx voteRegistrationTx
      case eResult of
        Left  (err :: AppError) -> fail $ show err
        Right ()                -> pure ()
