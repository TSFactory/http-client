{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Network.HTTP.Client.Connection where

import Data.ByteString (ByteString, empty)
import Data.IORef
import Control.Monad
import Control.Exception (throwIO)
import Network.HTTP.Client.Types
import Network.Socket (Socket, sClose, HostAddress, defaultHints, addrFlags)
import qualified Network.Socket as NS
import Network.Socket.ByteString (sendAll, recv)
import qualified Control.Exception as E
import qualified Data.ByteString as S
import Data.Word (Word8)

connectionReadLine :: Connection -> IO ByteString
connectionReadLine conn = do
    bs <- connectionRead conn
    when (S.null bs) $ throwIO IncompleteHeaders
    connectionReadLineWith conn bs

connectionReadLineWith :: Connection -> ByteString -> IO ByteString
connectionReadLineWith conn bs0 =
    go bs0 id 0
  where
    go bs front total =
        case S.breakByte charLF bs of
            (_, "") -> do
                let total' = total + S.length bs
                when (total' > 1024) $ throwIO OverlongHeaders
                bs' <- connectionRead conn
                when (S.null bs') $ throwIO IncompleteHeaders
                go bs' (front . (bs:)) total'
            (x, S.drop 1 -> y) -> do
                unless (S.null y) $! connectionUnread conn y
                return $! killCR $! S.concat $! front [x]

charLF, charCR, charSpace, charColon, charPeriod :: Word8
charLF = 10
charCR = 13
charSpace = 32
charColon = 58
charPeriod = 46

killCR :: ByteString -> ByteString
killCR bs
    | S.null bs = bs
    | S.last bs == charCR = S.init bs
    | otherwise = bs


-- | For testing
dummyConnection :: [ByteString] -- ^ input
                -> IO (Connection, IO [ByteString], IO [ByteString]) -- ^ conn, output, input
dummyConnection input0 = do
    iinput <- newIORef input0
    ioutput <- newIORef []
    return (Connection
        { connectionRead = atomicModifyIORef iinput $ \input ->
            case input of
                [] -> ([], empty)
                x:xs -> (xs, x)
        , connectionUnread = \x -> atomicModifyIORef iinput $ \input -> (x:input, ())
        , connectionWrite = \x -> atomicModifyIORef ioutput $ \output -> (output ++ [x], ())
        , connectionClose = return ()
        }, atomicModifyIORef ioutput $ \output -> ([], output), readIORef iinput)

makeConnection :: IO ByteString -- ^ read
               -> (ByteString -> IO ()) -- ^ write
               -> IO () -- ^ close
               -> IO Connection
makeConnection r w c = do
    istack <- newIORef []
    _ <- mkWeakIORef istack c
    return $! Connection
        { connectionRead = join $ atomicModifyIORef istack $ \stack ->
            case stack of
                x:xs -> (xs, return x)
                [] -> ([], r)
        , connectionUnread = \x -> atomicModifyIORef istack $ \stack -> (x:stack, ())
        , connectionWrite = w
        , connectionClose = c
        }

socketConnection :: Socket -> IO Connection
socketConnection socket = makeConnection
    (recv socket 4096)
    (sendAll socket)
    (sClose socket)

openSocketConnection :: Maybe HostAddress
                     -> String -- ^ host
                     -> Int -- ^ port
                     -> IO Connection
openSocketConnection hostAddress host port = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    addrs <- case hostAddress of
        Nothing ->
            NS.getAddrInfo (Just hints) (Just host) (Just $ show port)
        Just ha ->
            return
                [NS.AddrInfo
                 { NS.addrFlags = []
                 , NS.addrFamily = NS.AF_INET
                 , NS.addrSocketType = NS.Stream
                 , NS.addrProtocol = 6 -- tcp
                 , NS.addrAddress = NS.SockAddrInet (toEnum port) ha
                 , NS.addrCanonName = Nothing
                 }]

    firstSuccessful addrs $ \addr ->
        E.bracketOnError
            (NS.socket (NS.addrFamily addr) (NS.addrSocketType addr)
                       (NS.addrProtocol addr))
            (NS.sClose)
            (\sock -> do
                NS.setSocketOption sock NS.NoDelay 1
                NS.connect sock (NS.addrAddress addr)
                socketConnection sock)

firstSuccessful :: [NS.AddrInfo] -> (NS.AddrInfo -> IO a) -> IO a
firstSuccessful []     _  = error "getAddrInfo returned empty list"
firstSuccessful (a:as) cb =
    cb a `E.catch` \(e :: E.IOException) ->
        case as of
            [] -> E.throwIO e
            _  -> firstSuccessful as cb
