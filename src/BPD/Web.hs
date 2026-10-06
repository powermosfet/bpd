{-# LANGUAGE OverloadedStrings #-}
module BPD.Web (webApp) where

import BPD.Config
import BPD.Core
import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import Data.Time (defaultTimeLocale, formatTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Lucid
import Network.HTTP.Types.URI (urlEncode)
import Network.HTTP.Types.Status
import Network.Wai (Application)
import qualified Web.Scotty as S
import Web.Cookie (parseCookies)

webApp :: Config -> Desk -> IO Application
webApp config desk = do
  csrf <- UUID.toText <$> UUID.nextRandom
  S.scottyApp $ do
    -- 2000 four-byte characters take about 24 KB when form URL encoded.
    S.setMaxRequestBodySize 64
    S.get "/healthz" $ S.text "ok\n"
    S.get "/readyz" $ do
      view <- S.liftIO $ snapshot desk
      case queueCount view of
        Just _ -> S.text "ready\n"
        Nothing -> S.status status503 >> S.text "RabbitMQ unavailable\n"
    S.get "/" $ do
      view <- S.liftIO $ snapshot desk
      render csrf $ home config csrf view
    S.post "/claim" $ do
      checkCsrf csrf
      token <- S.liftIO $ fetchBarcode desk
      redirectTo $ maybe "/" claimUrl token
    S.get "/claim/:id" $ do
      token <- S.pathParam "id"
      view <- S.liftIO $ snapshot desk
      case activeClaim view of
        Just c | claimId c == token -> render csrf $ edit config csrf c
        _ -> do
          S.status status410
          render csrf $ page $ do
            h2_ "This claim is no longer active"
            p_ "It expired, was completed, or was released after a disconnect."
            a_ [href_ "/"] "Return to Barcode Product Desk"
    S.post "/claim/:id/save" $ do
      checkCsrf csrf
      token <- S.pathParam "id"
      desc <- fromMaybe "" <$> S.formParamMaybe "description"
      shopping <- (== Just ("on" :: Text)) <$> S.formParamMaybe "addToShoppingList"
      S.liftIO $ saveDescription desk token desc shopping
      view <- S.liftIO $ snapshot desk
      redirectTo $ case activeClaim view of
        Just c | claimId c == token -> claimUrl token
        _ -> "/"
    S.post "/claim/:id/return" $ do
      checkCsrf csrf
      token <- S.pathParam "id"
      S.liftIO $ returnBarcode desk token
      redirectTo "/"
    S.post "/claim/:id/drop" $ do
      checkCsrf csrf
      token <- S.pathParam "id"
      S.liftIO $ dropBarcode desk token
      redirectTo "/"
    S.notFound $ S.status status404 >> render csrf (page $ p_ "Page not found.")

claimUrl :: Text -> Text
claimUrl token = "/claim/" <> token

redirectTo :: Text -> S.ActionM a
redirectTo url = do
  S.status status303
  S.setHeader "Location" (TL.fromStrict url)
  S.finish

checkCsrf :: Text -> S.ActionM ()
checkCsrf expected = do
  cookieHeader <- S.header "Cookie"
  submitted <- S.formParamMaybe "csrf"
  let cookies = maybe [] (parseCookies . TE.encodeUtf8 . TL.toStrict) cookieHeader
      cookie = lookup "bpd-csrf" cookies
  unless (cookie == Just (TE.encodeUtf8 expected) && submitted == Just expected) $ do
    S.status status403
    S.html $ renderText $ page $ do
      h2_ "Form verification failed"
      p_ "Open BPD again and submit the form from there."
      a_ [href_ "/"] "Return home"
    S.finish

render :: Text -> Html () -> S.ActionM ()
render csrf document = do
  S.setHeader "Set-Cookie" $ TL.fromStrict $ "bpd-csrf=" <> csrf <> "; Path=/; HttpOnly; SameSite=Strict"
  S.setHeader "Cache-Control" "no-store"
  S.setHeader "Referrer-Policy" "no-referrer"
  S.setHeader "X-Content-Type-Options" "nosniff"
  S.setHeader "Content-Security-Policy" "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
  S.html $ renderText document

page :: Html () -> Html ()
page contents = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ "Barcode Product Desk"
    style_ ("body{font:18px/1.5 system-ui,sans-serif;color:#172b36;background:#f3f6f5;margin:0}main{max-width:42rem;margin:3rem auto;padding:1.5rem;background:white;border:1px solid #d7e0dc;border-radius:12px}h1{font-size:1.8rem;margin:0}a{color:#146047}label{display:block;font-weight:600;margin:.8rem 0}textarea{box-sizing:border-box;width:100%;font:inherit;padding:.7rem;border:1px solid #7a8c82;border-radius:5px}button{font:inherit;background:#146047;color:white;border:0;border-radius:5px;padding:.6rem 1rem;cursor:pointer}button.secondary{background:#e6ede9;color:#172b36}.notice{padding:.8rem;background:#fff4d6;border-left:4px solid #b08012}.count{font-size:2.4rem;font-weight:700;margin:.2rem 0}.barcode{font:1.7rem ui-monospace,monospace;overflow-wrap:anywhere}.muted{color:#52675b;font-size:.9rem}form{margin:1rem 0}@media(max-width:700px){main{margin:1rem;padding:1rem}}" :: Text)
  body_ $ main_ $ do
    h1_ $ a_ [href_ "/"] "Barcode Product Desk"
    p_ [class_ "muted"] "BPD · Resolve missing product descriptions"
    contents

hiddenCsrf :: Text -> Html ()
hiddenCsrf csrf = input_ [type_ "hidden", name_ "csrf", value_ csrf]

home :: Config -> Text -> View -> Html ()
home config csrf view = page $ do
  maybe (pure ()) (p_ [class_ "notice", role_ "status"] . toHtml) (notice view)
  h2_ "Ready in queue"
  p_ [class_ "count"] $ toHtml $ maybe "Unavailable" (T.pack . show) (queueCount view)
  p_ [class_ "muted"] $ toHtml $ "Queue: " <> rabbitQueue (rabbit config) <> ". Refresh this page to update the count."
  case activeClaim view of
    Just c -> do
      p_ "One barcode is currently being edited."
      a_ [href_ $ claimUrl $ claimId c] "Resume description form"
    Nothing -> case queueCount view of
      Nothing -> p_ "Waiting for RabbitMQ."
      Just _ -> form_ [method_ "post", action_ "/claim"] $ do
        hiddenCsrf csrf
        button_ [type_ "submit"] "Fetch barcode"

edit :: Config -> Text -> ClaimView -> Html ()
edit _config csrf c = page $ do
  h2_ "Describe this product"
  case barcode c of
    Right code -> do
      p_ [class_ "barcode"] $ toHtml code
      let query = TE.decodeUtf8 $ urlEncode False $ TE.encodeUtf8 code
      p_ $ do
        "Search barcode: "
        a_ [href_ $ "https://duckduckgo.com/?q=" <> query, target_ "_blank", rel_ "noopener noreferrer"] "DuckDuckGo"
        " · "
        a_ [href_ $ "https://www.google.com/search?q=" <> query, target_ "_blank", rel_ "noopener noreferrer"] "Google"
    Left _ -> p_ "This message does not contain a valid barcode."
  p_ [class_ "muted"] $ toHtml $ "Claim expires at " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC" $ expiresAt c) <> "."
  maybe (pure ()) (p_ [class_ "notice", role_ "alert"] . toHtml) (claimError c)
  case barcode c of
    Left _ -> pure ()
    Right _ -> form_ [method_ "post", action_ $ claimUrl (claimId c) <> "/save"] $ do
      hiddenCsrf csrf
      label_ [for_ "description"] "Product description"
      textarea_ ([id_ "description", name_ "description", rows_ "4", required_ "", maxlength_ "2000", autofocus_] ++ [readonly_ "" | productSaved c]) $ toHtml $ description c
      label_ [for_ "add-to-shopping-list"] $ do
        input_ $ [type_ "checkbox", id_ "add-to-shopping-list", name_ "addToShoppingList", value_ "on"] ++ [checked_ | addToShoppingList c]
        " Add to shopping list"
      button_ [type_ "submit"] "Save product"
  form_ [method_ "post", action_ $ claimUrl (claimId c) <> "/return"] $ do
    hiddenCsrf csrf
    button_ [type_ "submit", class_ "secondary"] "Return to queue"
  form_ [method_ "post", action_ $ claimUrl (claimId c) <> "/drop"] $ do
    hiddenCsrf csrf
    p_ [class_ "muted"] "If this barcode cannot be identified, drop it from the queue without saving a product."
    button_ [type_ "submit", class_ "secondary"] "Drop barcode"
  a_ [href_ "/"] "Back to queue"
