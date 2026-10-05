module Main (main) where

import BPD.Broker (makeBackend)
import BPD.Config
import BPD.Core
import BPD.Web (webApp)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (bracket)
import Control.Monad (forever, void)
import Data.String (fromString)
import Network.Wai.Handler.Warp
import System.Posix.Signals (installHandler, sigTERM, Handler(Catch))
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hSetBuffering, stdout, BufferMode(LineBuffering))

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["--config", configPath, "--rabbitmq-password-file", passwordPath] -> do
      (config, password) <- loadConfig configPath passwordPath
      backend <- makeBackend config password
      bracket (newDesk backend $ claimTimeoutSeconds config) closeDesk $ \desk -> do
        tick desk
        application <- webApp config desk
        let settings = setHost (fromString $ listenAddress config)
                     $ setPort (listenPort config)
                     $ setInstallShutdownHandler (\shutdown -> void $ installHandler sigTERM (Catch shutdown) Nothing)
                     $ setTimeout 30 defaultSettings
        putStrLn $ "Barcode Product Desk listening on " <> listenAddress config <> ":" <> show (listenPort config)
        withAsync (forever $ threadDelay 1000000 >> tick desk) $ \worker -> link worker >> runSettings settings application
    ["--help"] -> putStrLn usage
    _ -> die usage
  where usage = "Usage: bpd --config FILE.json --rabbitmq-password-file FILE\nSee README.md for configuration and NixOS deployment."
