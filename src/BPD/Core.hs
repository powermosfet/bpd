{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module BPD.Core
  ( Delivery(..), Session(..), Backend(..), Desk, View(..), ClaimView(..)
  , newDesk, tick, snapshot, fetchBarcode, saveDescription, returnBarcode, dropBarcode
  , closeDesk, decodeBarcode, validateDescription, trySync, bounded
  ) where

import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (void)
import qualified Data.ByteString as BS
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import System.Timeout (timeout)

-- Delivery actions close over their original channel. They must never be rebuilt
-- using a delivery tag on a recovered channel.
data Delivery = Delivery
  { deliveryBody :: BS.ByteString, acknowledge :: IO (), requeue :: IO () }
data Session = Session
  { sessionAlive :: IO Bool, readyCount :: IO Int
  , getDelivery :: IO (Maybe Delivery), closeSession :: IO ()
  , publishShopping :: Text -> Text -> IO () }
data Backend = Backend
  { connect :: IO Session, postProduct :: Text -> Text -> IO (Either Text ()) }
data Claim = Claim
  { claimView :: ClaimView, claimDelivery :: Delivery }
data ClaimView = ClaimView
  { claimId :: Text, barcode :: Either Text Text, description :: Text
  , expiresAt :: UTCTime, claimError :: Maybe Text
  , addToShoppingList :: Bool, productSaved :: Bool
  } deriving (Eq, Show)
data View = View
  { queueCount :: Maybe Int, activeClaim :: Maybe ClaimView, notice :: Maybe Text
  } deriving (Eq, Show)
data State = State
  { connection :: Maybe Session, current :: Maybe Claim, message :: Maybe Text
  , reconnectAt :: UTCTime, reconnectDelay :: Int }
data Desk = Desk Backend Int (MVar State)

trySync :: IO a -> IO (Either SomeException a)
trySync = tryJust $ \e -> case fromException e :: Maybe SomeAsyncException of
  Just _ -> Nothing
  Nothing -> Just e

bounded :: IO a -> IO a
bounded action = timeout (5 * 1000000) action >>= maybe
  (ioError $ userError "RabbitMQ operation timed out.") pure

newDesk :: Backend -> Int -> IO Desk
newDesk backend ttl = do
  now <- getCurrentTime
  Desk backend ttl <$> newMVar (State Nothing Nothing Nothing now 1)

-- Keep state commits masked. If an interrupt arrives during blocking I/O,
-- close the original session before modifyMVar restores the previous state.
-- Otherwise a fetched delivery could be orphaned, or an acknowledged claim
-- could remain available for submission a second time.
modifyState :: MVar State -> (State -> IO (State, a)) -> IO a
modifyState lock action = modifyMVarMasked lock $ \s ->
  action s `onException` maybe (pure ()) quietClose (connection s)

modifyState_ :: MVar State -> (State -> IO State) -> IO ()
modifyState_ lock action = modifyState lock $ \s -> do
  next <- action s
  pure (next, ())

-- Exceptions are deliberately not shown to browsers or logs: library exceptions
-- can include broker credentials or product URLs.
quietClose :: Session -> IO ()
quietClose session = void $ trySync $ bounded $ closeSession session

disconnect :: State -> Text -> IO State
disconnect s reason = do
  maybe (pure ()) quietClose (connection s)
  putStrLn $ "BPD: " <> T.unpack reason
  now <- getCurrentTime
  pure s { connection = Nothing, current = Nothing, message = Just reason
         , reconnectAt = addUTCTime (fromIntegral $ reconnectDelay s) now
         , reconnectDelay = min 30 (2 * reconnectDelay s) }

normalize :: State -> IO State
normalize s = case connection s of
  Nothing -> pure s
  Just session -> do
    alive <- sessionAlive session
    if not alive then disconnect s "RabbitMQ disconnected. Any active barcode may be redelivered."
    else do
      now <- getCurrentTime
      case current s of
        Just c | expiresAt (claimView c) <= now -> do
          result <- trySync $ bounded $ requeue (claimDelivery c)
          case result of
            Left _ -> disconnect s "The claim expired while RabbitMQ was unavailable; it may be redelivered."
            Right () -> pure s { current = Nothing, message = Just "The claim expired and was returned to the queue." }
        _ -> pure s

tick :: Desk -> IO ()
tick (Desk backend _ lock) = modifyState_ lock $ \s0 -> do
  s <- normalize s0
  now <- getCurrentTime
  case connection s of
    Just _ -> pure s
    Nothing | now < reconnectAt s -> pure s
    Nothing -> do
      result <- trySync $ bounded $ connect backend
      case result of
        Left _ -> disconnect s "RabbitMQ is unavailable. BPD will reconnect automatically."
        Right session -> do
          putStrLn "BPD: RabbitMQ connected."
          let unavailable = Just "RabbitMQ is unavailable. BPD will reconnect automatically."
          pure s { connection = Just session, reconnectDelay = 1
                 , message = if message s == unavailable then Nothing else message s }

snapshot :: Desk -> IO View
snapshot (Desk _ _ lock) = modifyState lock $ \s0 -> do
  s <- normalize s0
  case connection s of
    Nothing -> pure (s, view s Nothing)
    Just session -> do
      result <- trySync $ bounded $ readyCount session
      case result of
        Right count -> pure (s, view s (Just count))
        Left _ -> do
          failed <- disconnect s "Cannot inspect the queue. Check RabbitMQ connectivity, queue name, and permissions."
          pure (failed, view failed Nothing)
  where view s n = View n (claimView <$> current s) (message s)

fetchBarcode :: Desk -> IO (Maybe Text)
fetchBarcode (Desk _ ttl lock) = modifyState lock $ \s0 -> do
  s <- normalize s0
  case current s of
    Just c -> pure (s, Just $ claimId $ claimView c)
    Nothing -> case connection s of
      Nothing -> pure (s { message = Just "RabbitMQ is unavailable. Please try again after it reconnects." }, Nothing)
      Just session -> do
        result <- trySync $ bounded $ getDelivery session
        case result of
          Left _ -> do
            failed <- disconnect s "Fetching failed. The barcode remains pending in RabbitMQ."
            pure (failed, Nothing)
          Right Nothing -> pure (s { message = Just "The queue is empty." }, Nothing)
          Right (Just delivery) -> do
            token <- UUID.toText <$> UUID.nextRandom
            now <- getCurrentTime
            let decoded = decodeBarcode (deliveryBody delivery)
                v = ClaimView token decoded "" (addUTCTime (fromIntegral ttl) now) (either Just (const Nothing) decoded) True False
            pure (s { current = Just (Claim v delivery), message = Nothing }, Just token)

saveDescription :: Desk -> Text -> Text -> Bool -> IO ()
saveDescription (Desk backend _ lock) token input shopping = modifyState_ lock $ \s0 -> do
  s <- normalize s0
  case current s of
    Just c | claimId (claimView c) == token -> case (barcode $ claimView c, validateDescription input) of
      (Left err, _) -> pure $ failedForm s c input err
      (_, Left err) -> pure $ failedForm s c input err
      (Right _, Right desc) | productSaved (claimView c) && desc /= description (claimView c) ->
        pure $ failedForm s c (description $ claimView c) "This product is already saved. Retry with its saved description to finish adding it to the shopping list."
      (Right code, Right desc) -> do
        result <- if productSaved (claimView c) then pure (Right (Right ()))
          else trySync $ postProduct backend code desc
        case result of
          Left _ -> pure $ failedForm s c input "The save response was lost or timed out. The product may have been saved; retrying may produce a duplicate error."
          Right (Left err) -> pure $ failedForm s c input err
          Right (Right ()) -> do
            let saved = c { claimView = (claimView c) { description = desc, productSaved = True, addToShoppingList = shopping } }
            published <- trySync $ bounded $ if shopping
              then maybe (ioError $ userError "RabbitMQ unavailable.") (\session -> publishShopping session code desc) (connection s)
              else pure ()
            case published of
              Left _ -> pure $ failedForm s saved desc "Product saved, but adding it to the shopping list could not be confirmed. Retry to finish without saving the product again; the shopping list may receive a duplicate."
              Right () -> do
                ack <- trySync $ bounded $ do
                  alive <- maybe (pure False) sessionAlive (connection s)
                  if alive then acknowledge (claimDelivery c)
                    else ioError $ userError "Connection lost before acknowledgement."
                case ack of
                  Right () -> pure s { current = Nothing, message = Just $ if shopping then "Product saved and added to shopping list." else "Product saved." }
                  Left _ -> disconnect s "The product was saved, but queue acknowledgement is uncertain. The barcode may be redelivered."
    _ -> pure s { message = Just "This form is stale or its claim has expired. Fetch or resume a barcode from the home page." }
  where failedForm s c desc err = s { current = Just c { claimView = (claimView c) { description = if productSaved (claimView c) then description (claimView c) else desc, claimError = Just err, addToShoppingList = shopping } } }

returnBarcode :: Desk -> Text -> IO ()
returnBarcode (Desk _ _ lock) token = modifyState_ lock $ \s0 -> do
  s <- normalize s0
  case current s of
    Just c | claimId (claimView c) == token -> do
      result <- trySync $ bounded $ requeue (claimDelivery c)
      case result of
        Right () -> pure s { current = Nothing, message = Just "Barcode returned to the queue." }
        Left _ -> disconnect s "Could not confirm return to the queue. The barcode may be redelivered."
    _ -> pure s { message = Just "This form is stale or its claim has expired." }

-- Deliberately discard a delivery without creating a product.
dropBarcode :: Desk -> Text -> IO ()
dropBarcode (Desk _ _ lock) token = modifyState_ lock $ \s0 -> do
  s <- normalize s0
  case current s of
    Just c | claimId (claimView c) == token -> do
      result <- trySync $ bounded $ acknowledge (claimDelivery c)
      case result of
        Right () -> pure s { current = Nothing, message = Just "Barcode dropped without saving a product." }
        Left _ -> disconnect s "Could not confirm dropping the barcode. The barcode may be redelivered."
    _ -> pure s { message = Just "This form is stale or its claim has expired." }

closeDesk :: Desk -> IO ()
closeDesk (Desk _ _ lock) = modifyState_ lock $ \s -> do
  maybe (pure ()) quietClose (connection s)
  pure s { connection = Nothing, current = Nothing }

decodeBarcode :: BS.ByteString -> Either Text Text
decodeBarcode bytes = case TE.decodeUtf8' bytes of
  Left _ -> Left "Invalid payload: the barcode is not UTF-8 text. Return it to the queue for investigation."
  Right code
    | T.null code || T.length code > 256 || T.any (\c -> isSpace c || isControl c || c == '"') code ->
        Left "Invalid payload: expected an unquoted barcode string without whitespace, at most 256 characters."
    | otherwise -> Right code

validateDescription :: Text -> Either Text Text
validateDescription desc
  | T.null trimmed = Left "Enter a description."
  | T.length trimmed > 2000 = Left "The description must be at most 2000 characters."
  | T.any (\c -> isControl c && c /= '\n' && c /= '\r' && c /= '\t') trimmed = Left "The description contains invalid control characters."
  | otherwise = Right trimmed
  where trimmed = T.strip desc
