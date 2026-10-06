{-# LANGUAGE OverloadedStrings #-}
module BPD.Broker (makeBackend) where

import BPD.Config
import BPD.Core
import Control.Exception (bracket, bracketOnError)
import Control.Monad (void)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Network.AMQP
import qualified Network.HTTP.Client as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import System.Timeout (timeout)

makeBackend :: Config -> Text -> IO Backend
makeBackend config password = do
  manager <- HTTP.newManager tlsManagerSettings
    { HTTP.managerRetryableException = const False }
  template <- HTTP.parseRequest (productUrl config)
  pure Backend
    { connect = openSession
    , postProduct = \code desc -> do
        let request = template
              { HTTP.method = "POST"
              , HTTP.requestHeaders = [("Content-Type", "application/json"), ("Accept", "application/json")]
              , HTTP.requestBody = HTTP.RequestBodyLBS $ encode $ object ["barcode" .= code, "description" .= desc]
              , HTTP.responseTimeout = HTTP.responseTimeoutMicro 10000000
              , HTTP.redirectCount = 0
              , HTTP.checkResponse = \_ _ -> pure ()
              }
        response <- timeout 10000000 $ HTTP.httpNoBody request manager
        case response of
          Nothing -> ioError $ userError "Product request timed out."
          Just reply -> let code' = statusCode (HTTP.responseStatus reply) in
            pure $ if code' >= 200 && code' < 300 then Right () else Left $
              "The product service returned HTTP " <> T.pack (show code') <>
              ". The barcode is still pending. A duplicate barcode currently also returns 500; BPD cannot safely treat that as success."
    }
  where
    r = rabbit config
    passive = newQueue { queueName = rabbitQueue r, queuePassive = True }
    openSession = bracketOnError
      (openConnection'' defaultConnectionOpts
        { coServers = [(rabbitHost r, fromIntegral $ rabbitPort r)]
        , coVHost = rabbitVHost r
        , coAuth = [plain (rabbitUser r) password]
        , coHeartbeatDelay = Just 10
        , coName = Just "Barcode Product Desk"
        }) closeConnection $ \conn -> do
      alive <- newIORef True
      addConnectionClosedHandler conn True (writeIORef alive False)
      deliveryChannel <- openChannel conn
      statsChannel <- openChannel conn
      let markClosed _ = writeIORef alive False
      addChannelExceptionHandler deliveryChannel markClosed
      addChannelExceptionHandler statsChannel markClosed
      -- Passive declarations never create or change queue properties.
      void $ declareQueue statsChannel passive
      let barrier = void $ declareQueue deliveryChannel passive
          count = do (_, n, _) <- declareQueue statsChannel passive; pure n
          fetch = fmap (fmap $ \(msg, env) -> Delivery
            { deliveryBody = BL.toStrict $ msgBody msg
            -- An ordered RPC on the same channel provides a round trip after
            -- the one-way acknowledgement/rejection before showing success.
            , acknowledge = ackEnv env >> barrier
            , requeue = rejectEnv env True >> barrier
            }) $ getMsg deliveryChannel Ack (rabbitQueue r)
      pure Session
        { sessionAlive = readIORef alive, readyCount = count
        , getDelivery = fetch, closeSession = closeConnection conn
        , publishShopping = \code desc -> bracket (openChannel conn) closeChannel $ \channel -> do
            -- A separate channel leaves the active claim usable if the target
            -- queue is missing or publishing permissions are denied.
            void $ declareQueue channel newQueue { queueName = shoppingListQueue r, queuePassive = True }
            returned <- newIORef False
            addReturnListener channel (\_ -> writeIORef returned True)
            confirmSelect channel False
            void $ publishMsg' channel "" (shoppingListQueue r) True newMsg
              { msgBody = encode $ object ["barcode" .= code, "description" .= desc]
              , msgContentType = Just "application/json"
              , msgDeliveryMode = Just Persistent
              }
            confirmation <- waitForConfirms channel
            wasReturned <- readIORef returned
            case confirmation of
              Complete (_, nacks) | nacks == mempty && not wasReturned -> pure ()
              _ -> ioError $ userError "Shopping-list message was not confirmed."
        }
