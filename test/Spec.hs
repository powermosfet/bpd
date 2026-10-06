{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import BPD.Config
import BPD.Core
import BPD.Web
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.Async (cancel, concurrently, withAsync)
import Control.Monad (void)
import Data.Aeson (eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Test
import Test.Hspec hiding (pending)

-- A deterministic broker adapter exercises lifecycle behavior without depending
-- on a local daemon. The NixOS test also runs the real AMQP adapter.
data Fake = Fake
  { fakeBackend :: Backend, pending :: IORef [BS.ByteString]
  , acknowledgements :: IORef Int, posted :: IORef [(Text, Text)]
  , response :: IORef (Either Text ()), connected :: IORef Bool
  , failAck :: IORef Bool, beforePost :: IORef (IO ())
  , shoppingPosts :: IORef [(Text, Text)], failShopping :: IORef Bool }

fake :: [BS.ByteString] -> IO Fake
fake payloads = do
  queue <- newIORef payloads
  acks <- newIORef 0
  posts <- newIORef []
  reply <- newIORef (Right ())
  alive <- newIORef True
  ackFailure <- newIORef False
  hook <- newIORef (pure ())
  shopping <- newIORef []
  shoppingFailure <- newIORef False
  let session = Session
        { sessionAlive = readIORef alive
        , readyCount = length <$> readIORef queue
        , closeSession = writeIORef alive False
        , publishShopping = \code desc -> do
            shouldFail <- readIORef shoppingFailure
            if shouldFail then ioError (userError "shopping publish failed")
              else modifyIORef' shopping (++ [(code, desc)])
        , getDelivery = do
            payload <- atomicModifyIORef' queue $ \xs -> case xs of
              [] -> ([], Nothing)
              x:rest -> (rest, Just x)
            pure $ fmap (\p -> Delivery p
              (do shouldFail <- readIORef ackFailure
                  if shouldFail then ioError (userError "lost ack") else modifyIORef' acks (+1))
              (atomicModifyIORef' queue $ \xs -> (p:xs, ()))) payload
        }
      backend = Backend
        { connect = writeIORef alive True >> pure session
        , postProduct = \code desc -> do
            readIORef hook >>= id
            atomicModifyIORef' posts $ \xs -> (xs ++ [(code, desc)], ())
            readIORef reply
        }
  pure $ Fake backend queue acks posts reply alive ackFailure hook shopping shoppingFailure

setup :: [BS.ByteString] -> Int -> IO (Fake, Desk)
setup payloads ttl = do
  f <- fake payloads
  d <- newDesk (fakeBackend f) ttl
  tick d
  pure (f, d)

claim :: Desk -> IO Text
claim d = fetchBarcode d >>= maybe (fail "expected claim") pure

main :: IO ()
main = hspec $ do
  describe "barcode and description validation" $ do
    it "preserves leading zeros" $ decodeBarcode "000786534249" `shouldBe` Right "000786534249"
    it "rejects non-UTF8, JSON quoting, empty and whitespace payloads" $
      mapM_ (\p -> decodeBarcode p `shouldSatisfy` either (const True) (const False)) ["", "\xff", "\"123\"", "12\n3", " 123"]
    it "trims descriptions and accepts Unicode" $ validateDescription "  Café milk  " `shouldBe` Right "Café milk"
    it "rejects blank and oversized descriptions" $
      mapM_ (\p -> validateDescription p `shouldSatisfy` either (const True) (const False)) [" \n", T.replicate 2001 "x"]
    it "rejects invalid configuration" $ do
      validateConfig defaultConfig { listenPort = 0 } `shouldSatisfy` either (const True) (const False)
      validateConfig defaultConfig { claimTimeoutSeconds = 0 } `shouldSatisfy` either (const True) (const False)
      validateConfig defaultConfig { rabbit = (rabbit defaultConfig) { shoppingListQueue = "" } } `shouldSatisfy` either (const True) (const False)
      validateConfig defaultConfig { rabbit = (rabbit defaultConfig) { shoppingListQueue = "missing-barcodes" } } `shouldSatisfy` either (const True) (const False)
    it "defaults and configures the shopping-list queue" $ do
      (eitherDecode "{}" :: Either String Config) `shouldBe` Right defaultConfig
      fmap (shoppingListQueue . rabbit) (eitherDecode "{\"rabbitmq\":{\"shoppingListQueue\":\"groceries\"}}" :: Either String Config) `shouldBe` Right "groceries"
  describe "claim lifecycle" $ do
    it "handles an empty queue" $ do
      (_, d) <- setup [] 900
      fetchBarcode d `shouldReturn` Nothing
      queueCount <$> snapshot d `shouldReturn` Just 0
    it "claims once and resumes on repeated fetches" $ do
      (f, d) <- setup ["001", "002"] 900
      token <- claim d
      fetchBarcode d `shouldReturn` Just token
      readIORef (pending f) `shouldReturn` ["002"]
      readIORef (acknowledgements f) `shouldReturn` 0
    it "posts text and acknowledges only a successful save" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      saveDescription d token "  Milk  " True
      readIORef (posted f) `shouldReturn` [("001", "Milk")]
      readIORef (shoppingPosts f) `shouldReturn` [("001", "Milk")]
      readIORef (acknowledgements f) `shouldReturn` 1
      activeClaim <$> snapshot d `shouldReturn` Nothing
    it "saves without publishing when shopping is unchecked" $ do
      (f, d) <- setup ["0000000"] 900
      token <- claim d
      saveDescription d token "Apples" False
      readIORef (posted f) `shouldReturn` [("0000000", "Apples")]
      readIORef (shoppingPosts f) `shouldReturn` []
      readIORef (acknowledgements f) `shouldReturn` 1
    it "retries failed shopping publication without posting the product again" $ do
      (f, d) <- setup ["0000000"] 900
      token <- claim d
      writeIORef (failShopping f) True
      saveDescription d token "  Apples  " True
      readIORef (acknowledgements f) `shouldReturn` 0
      productSaved . maybe (error "missing claim") id . activeClaim <$> snapshot d `shouldReturn` True
      saveDescription d token "Pears" True
      description . maybe (error "missing claim") id . activeClaim <$> snapshot d `shouldReturn` "Apples"
      writeIORef (failShopping f) False
      saveDescription d token "Apples" True
      saveDescription d token "Apples" True
      readIORef (posted f) `shouldReturn` [("0000000", "Apples")]
      readIORef (shoppingPosts f) `shouldReturn` [("0000000", "Apples")]
      readIORef (acknowledgements f) `shouldReturn` 1
    it "retains failed form input without acknowledging" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      writeIORef (response f) $ Left "HTTP 500"
      saveDescription d token "My milk" True
      v <- snapshot d
      (description <$> activeClaim v) `shouldBe` Just "My milk"
      (claimError =<< activeClaim v) `shouldBe` Just "HTTP 500"
      readIORef (acknowledgements f) `shouldReturn` 0
      readIORef (shoppingPosts f) `shouldReturn` []
    it "retains input after network errors" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      writeIORef (beforePost f) $ ioError $ userError "timeout"
      saveDescription d token "Milk" True
      description . maybe (error "missing claim") id . activeClaim <$> snapshot d `shouldReturn` "Milk"
      readIORef (acknowledgements f) `shouldReturn` 0
    it "does not POST blank descriptions or invalid payloads" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      saveDescription d token "  " True
      (bad, invalid) <- setup ["\xff"] 900
      badToken <- claim invalid
      saveDescription invalid badToken "Milk" True
      readIORef (posted f) `shouldReturn` []
      readIORef (posted bad) `shouldReturn` []
    it "returns the barcode without posting or acknowledging" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      returnBarcode d token
      readIORef (pending f) `shouldReturn` ["001"]
      readIORef (acknowledgements f) `shouldReturn` 0
    it "drops unknown and invalid barcodes without posting or requeueing" $ do
      mapM_ (\payload -> do
        (f, d) <- setup [payload, "002"] 900
        token <- claim d
        dropBarcode d token
        dropBarcode d token
        readIORef (pending f) `shouldReturn` ["002"]
        readIORef (posted f) `shouldReturn` []
        readIORef (acknowledgements f) `shouldReturn` 1
        activeClaim <$> snapshot d `shouldReturn` Nothing
        next <- claim d
        dropBarcode d token
        claimId . maybe (error "missing claim") id . activeClaim <$> snapshot d `shouldReturn` next
        readIORef (acknowledgements f) `shouldReturn` 1) ["001", "\xff"]
    it "reports uncertain drops and invalidates the claim" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      writeIORef (failAck f) True
      dropBarcode d token
      v <- snapshot d
      activeClaim v `shouldBe` Nothing
      notice v `shouldSatisfy` maybe False (T.isInfixOf "Could not confirm dropping")
      readIORef (connected f) `shouldReturn` False
      readIORef (posted f) `shouldReturn` []
    it "does not drop expired claims" $ do
      (f, d) <- setup ["001"] 0
      token <- claim d
      dropBarcode d token
      readIORef (pending f) `shouldReturn` ["001"]
      readIORef (acknowledgements f) `shouldReturn` 0
    it "rejects a stale form after a new claim" $ do
      (f, d) <- setup ["001", "002"] 900
      old <- claim d
      saveDescription d old "First" True
      next <- claim d
      saveDescription d old "Stale" True
      claimId . maybe (error "missing claim") id . activeClaim <$> snapshot d `shouldReturn` next
      readIORef (posted f) `shouldReturn` [("001", "First")]
    it "serializes concurrent submissions and posts only once" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      void $ concurrently (saveDescription d token "Milk" True) (saveDescription d token "Milk" True)
      length <$> readIORef (posted f) `shouldReturn` 1
      readIORef (acknowledgements f) `shouldReturn` 1
    it "expires abandoned claims and rejects their forms" $ do
      (f, d) <- setup ["001"] 1
      token <- claim d
      threadDelay 1100000
      tick d
      saveDescription d token "Too late" True
      readIORef (pending f) `shouldReturn` ["001"]
      readIORef (posted f) `shouldReturn` []
    it "lets an in-progress save complete past expiry" $ do
      (f, d) <- setup ["001"] 1
      token <- claim d
      writeIORef (beforePost f) $ threadDelay 1100000
      saveDescription d token "Milk" True
      tick d
      readIORef (acknowledgements f) `shouldReturn` 1
    it "invalidates claims after disconnect" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      writeIORef (connected f) False
      saveDescription d token "Milk" True
      readIORef (posted f) `shouldReturn` []
      activeClaim <$> snapshot d `shouldReturn` Nothing
    it "closes the session when a save is interrupted" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      started <- newEmptyMVar
      writeIORef (beforePost f) $ putMVar started () >> threadDelay 10000000
      withAsync (saveDescription d token "Milk" True) $ \worker -> do
        takeMVar started
        cancel worker
      readIORef (connected f) `shouldReturn` False
      activeClaim <$> snapshot d `shouldReturn` Nothing
      readIORef (acknowledgements f) `shouldReturn` 0
    it "reports uncertain acknowledgements after successful writes" $ do
      (f, d) <- setup ["001"] 900
      token <- claim d
      writeIORef (failAck f) True
      saveDescription d token "Milk" True
      v <- snapshot d
      activeClaim v `shouldBe` Nothing
      notice v `shouldSatisfy` maybe False (T.isInfixOf "acknowledgement is uncertain")
      readIORef (posted f) `shouldReturn` [("001", "Milk")]
  describe "server-rendered interface" $ do
    it "rejects POSTs without CSRF verification" $ do
      (_, d) <- setup ["001"] 900
      app <- webApp defaultConfig d
      r <- runSession (request defaultRequest { requestMethod = "POST", rawPathInfo = "/claim", pathInfo = ["claim"] }) app
      simpleStatus r `shouldBe` status403
      activeClaim <$> snapshot d `shouldReturn` Nothing
    it "uses forms and 303 redirects and escapes saved input" $ do
      (f, d) <- setup ["001"] 900
      writeIORef (response f) $ Left "HTTP 500"
      app <- webApp defaultConfig d
      home <- runSession (request defaultRequest) app
      let cookie = B8.takeWhile (/= ';') $ maybe (error "missing cookie") id $ lookup "Set-Cookie" (simpleHeaders home)
          csrf = B8.drop (BS.length "bpd-csrf=") cookie
          form path fields = SRequest
            ((setPath defaultRequest path) { requestMethod = "POST", requestHeaders = [(hCookie, cookie), (hContentType, "application/x-www-form-urlencoded")] })
            (BL.fromStrict $ renderSimpleQuery False (("csrf", csrf):fields))
      fetched <- runSession (srequest $ form "/claim" []) app
      simpleStatus fetched `shouldBe` status303
      let location = maybe (error "missing redirect") id $ lookup hLocation (simpleHeaders fetched)
      initial <- runSession (request $ setPath defaultRequest location) app
      BL.toStrict (simpleBody initial) `shouldSatisfy` BS.isInfixOf "name=\"addToShoppingList\" value=\"on\" checked"
      saved <- runSession (srequest $ form (location <> "/save") [("description", "<script>alert(1)</script>")]) app
      simpleStatus saved `shouldBe` status303
      edit <- runSession (request $ setPath defaultRequest location) app
      let body = TE.decodeUtf8 $ BL.toStrict $ simpleBody edit
      body `shouldSatisfy` T.isInfixOf "&lt;script&gt;alert(1)&lt;/script&gt;"
      body `shouldSatisfy` (not . T.isInfixOf "<script>")
      body `shouldSatisfy` T.isInfixOf "Add to shopping list"
      body `shouldSatisfy` (not . T.isInfixOf "value=\"on\" checked")
      readIORef (acknowledgements f) `shouldReturn` 0
      let unicode = T.replicate 2000 "😀"
      writeIORef (response f) $ Right ()
      unicodeSaved <- runSession (srequest $ form (location <> "/save") [("description", TE.encodeUtf8 unicode), ("addToShoppingList", "on")]) app
      simpleStatus unicodeSaved `shouldBe` status303
      last <$> readIORef (posted f) `shouldReturn` ("001", unicode)
      readIORef (shoppingPosts f) `shouldReturn` [("001", unicode)]
      writeIORef (pending f) ["002"]
      next <- runSession (srequest $ form "/claim" []) app
      let nextLocation = maybe (error "missing redirect") id $ lookup hLocation (simpleHeaders next)
      unchecked <- runSession (srequest $ form (nextLocation <> "/save") [("description", "Apples")]) app
      simpleStatus unchecked `shouldBe` status303
      last <$> readIORef (posted f) `shouldReturn` ("002", "Apples")
      readIORef (shoppingPosts f) `shouldReturn` [("001", unicode)]
    it "returns Gone for completed claim pages" $ do
      (_, d) <- setup ["001"] 900
      token <- claim d
      saveDescription d token "Milk" True
      app <- webApp defaultConfig d
      r <- runSession (request $ setPath defaultRequest $ TE.encodeUtf8 $ "/claim/" <> token) app
      simpleStatus r `shouldBe` status410
