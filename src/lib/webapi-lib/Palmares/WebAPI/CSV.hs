{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

-- | CSV as a servant content type, for the list endpoints' @Accept@ negotiation.
--
-- The instance lives here, beside 'Palmares.WebAPI.Envelope.Page', because that is the only place
-- it is not an orphan: @MimeRender CSV (Page a)@ mentions a class from @servant@ and a type from
-- this library, so declaring it anywhere else would make it an instance a consumer can fail to
-- import.
module Palmares.WebAPI.CSV
  ( CSV,
    safeCell,
  )
where

import Data.Csv (DefaultOrdered, ToNamedRecord, encodeDefaultOrderedByName)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Media ((//), (/:))
import Palmares.WebAPI.Envelope (Page (..))
import Servant (Accept (..), MimeRender (..))

-- | The @text\/csv@ content type.
data CSV

instance Accept CSV where
  contentType _ = "text" // "csv" /: ("charset", "utf-8")

-- | The rows, and only the rows.
--
-- The page envelope is dropped: @total@, @limit@, @offset@ and @next_cursor@ have no CSV meaning,
-- and a reader that opened the file in a spreadsheet would find them in a data row. A client that
-- needs them asks for JSON, where they are already echoed.
instance (ToNamedRecord a, DefaultOrdered a) => MimeRender CSV (Page a) where
  mimeRender _ = encodeDefaultOrderedByName . pageItems

-- | Neutralise a cell a spreadsheet would execute.
--
-- Exported governance data lands in Excel, LibreOffice and Google Sheets, all of which treat a
-- cell beginning @=@, @+@, @-@ or @\@@ as a formula — so a DRep whose published name began with
-- @=@ could make a reader's spreadsheet fetch a URL or read another sheet. A leading tab or
-- carriage return is included because those are stripped before the formula test, which turns
-- @\\t=cmd@ back into a formula.
--
-- The guard is a single leading apostrophe, which every one of the three reads as \"this is text\"
-- and displays as nothing. Quoting is NOT a substitute: cassava already quotes a cell containing
-- a comma or a newline, and a quoted @\"=1+1\"@ is still a formula once the quotes are consumed.
--
-- Every @Text@ cell in every @ToNamedRecord@ instance goes through this. A numeric or boolean
-- cell cannot carry a formula and does not need it.
safeCell :: Text -> Text
safeCell c
  | Just (ch, _) <- T.uncons c, ch `elem` ("=+-@\t\r" :: String) = T.cons '\'' c
  | otherwise = c
