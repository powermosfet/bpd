{-# LANGUAGE OverloadedStrings #-}
module BPD.Config
  ( Config(..), RabbitConfig(..), defaultConfig, loadConfig, validateConfig ) where

import Data.Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Network.HTTP.Client (parseRequest, secure, host, method)

data RabbitConfig = RabbitConfig
  { rabbitHost :: String, rabbitPort :: Int, rabbitVHost :: Text
  , rabbitUser :: Text, rabbitQueue :: Text, shoppingListQueue :: Text
  } deriving (Eq, Show)

data Config = Config
  { listenAddress :: String, listenPort :: Int, productUrl :: String
  , claimTimeoutSeconds :: Int, rabbit :: RabbitConfig
  } deriving (Eq, Show)

defaultConfig :: Config
defaultConfig = Config "127.0.0.1" 8080 "http://mook.local:8003/api/product" 900
  (RabbitConfig "localhost" 5672 "/" "guest" "missing-barcodes" "shopping-list")

instance FromJSON RabbitConfig where
  parseJSON = withObject "RabbitMQ settings" $ \o -> RabbitConfig
    <$> o .:? "host" .!= rabbitHost r <*> o .:? "port" .!= rabbitPort r
    <*> o .:? "vhost" .!= rabbitVHost r <*> o .:? "username" .!= rabbitUser r
    <*> o .:? "queue" .!= rabbitQueue r
    <*> o .:? "shoppingListQueue" .!= shoppingListQueue r
    where r = rabbit defaultConfig

instance FromJSON Config where
  parseJSON = withObject "BPD settings" $ \o -> Config
    <$> o .:? "listenAddress" .!= listenAddress d
    <*> o .:? "listenPort" .!= listenPort d
    <*> o .:? "productUrl" .!= productUrl d
    <*> o .:? "claimTimeoutSeconds" .!= claimTimeoutSeconds d
    <*> o .:? "rabbitmq" .!= rabbit d
    where d = defaultConfig

validateConfig :: Config -> Either String Config
validateConfig c
  | any (\n -> n < 1 || n > 65535) [listenPort c, rabbitPort (rabbit c)] = Left "Ports must be between 1 and 65535."
  | claimTimeoutSeconds c < 1 = Left "claimTimeoutSeconds must be positive."
  | null (listenAddress c) || null (rabbitHost (rabbit c)) = Left "Listen address and RabbitMQ host must not be empty."
  | T.null (rabbitQueue (rabbit c)) = Left "RabbitMQ queue must not be empty."
  | T.null (shoppingListQueue (rabbit c)) = Left "RabbitMQ shoppingListQueue must not be empty."
  | shoppingListQueue (rabbit c) == rabbitQueue (rabbit c) = Left "RabbitMQ shoppingListQueue must differ from the barcode queue."
  | not ("http://" `T.isPrefixOf` url || "https://" `T.isPrefixOf` url) = Left "productUrl must use http:// or https://."
  | otherwise = Right c
  where url = T.pack (productUrl c)

loadConfig :: FilePath -> FilePath -> IO (Config, Text)
loadConfig configPath passwordPath = do
  bytes <- BS.readFile configPath
  c <- either (ioError . userError) pure (eitherDecodeStrict' bytes >>= validateConfig)
  -- Validate before starting the server, and reject URL-embedded methods.
  request <- parseRequest (productUrl c)
  if BS.null (host request) || method request /= "GET"
    then ioError (userError "productUrl must be an absolute HTTP URL without a method prefix.")
    else secure request `seq` pure ()
  secret <- T.dropWhileEnd (\x -> x == '\n' || x == '\r') <$> T.readFile passwordPath
  if T.null secret then ioError (userError "RabbitMQ password file is empty.") else pure (c, secret)
