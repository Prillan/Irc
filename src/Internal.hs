{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Irc.Internal where
import Data.String ( IsString(..) )
import Data.Default ( Default(..) )
import Data.Maybe ( maybe )
import Data.Monoid ( Monoid(mempty, mappend) )
import Control.Applicative (Applicative)
import Control.Monad.Trans.State as State
        ( State, put, modify, execState )
import Data.List (find, length, isPrefixOf)
import Network
import System.IO
import System.Exit
import Control.Monad.Reader
import Control.Exception
import Text.Printf
import Prelude hiding (catch)

--
-- The 'Net' monad, a wrapper over IO, carrying the bot's immutable state.
-- A socket and the bot's start time.
--
type Net = ReaderT Bot IO
data Bot = Bot { rules :: [Rule]
               , config :: Config
               , socket :: Handle}

data Config = Config { server :: String
                     , port :: Integer
                     , chan :: String
                     , nick :: String}

--
-- Set up actions to run on start and end, and run the main loop
--
mainWithConfigAndBehavior :: Config -> Behavior -> IO ()
mainWithConfigAndBehavior conf bev = bracket (connect conf bev) disconnect loop
  where
    disconnect = hClose . socket
    loop st    = runReaderT run st

main :: IO ()
main = mainWithConfigAndBehavior (Config
                                  "irc.freenode.org"
                                  6667
                                  "#yunbot-testing"
                                  "yunbot") $ do
         "!echo " |! (\x -> return $ drop 6 x)
         "!reverse " |! (\x -> return $ reverse $ drop 9 x)
--
-- Connect to the server and return the initial bot state
--
connect :: Config -> Behavior -> IO Bot
connect conf bev = notify $ do
    h <- connectTo (server conf) (PortNumber (fromIntegral (port conf)))
    hSetBuffering h NoBuffering
    return (Bot (runBevhavior bev) conf h)
  where
    notify a = bracket_
        (printf "Connecting to %s ... " (server conf) >> hFlush stdout)
        (putStrLn "done.")
        a

--
-- We're in the Net monad now, so we've connected successfully
-- Join a channel, and start processing commands
--
run :: Net ()
run = do
    conf <- asks config
    write "NICK" $ nick conf
    write "USER" $ nick conf ++ " 0 * :bot"
    write "JOIN" $ chan conf
    asks socket >>= listen

--
-- Process each line from the server
--
listen :: Handle -> Net ()
listen h = forever $ do
    s <- init `fmap` io (hGetLine h)
    io (putStrLn s)
    if ping s then pong s else eval (clean s)
  where
    forever a = a >> forever a
    clean     = drop 1 . dropWhile (/= ':') . drop 1
    ping x    = "PING :" `isPrefixOf` x
    pong x    = write "PONG" (':' : drop 6 x)

--
-- Dispatch a command
--
eval :: String -> Net ()
eval s = do
    r <- asks rules
    (liftAction (findAction s r)) s

findAction :: String -> [Rule] -> Action
findAction s l = maybe doNothing (\r -> action r) $ find (\x -> pattern x `isPrefixOf` s) l
                 where doNothing _ = return ""

--
-- Send a privmsg to the current chan + server
--
privmsg :: String -> Net ()
privmsg s = do
  conf <- asks config
  write "PRIVMSG" ((chan conf) ++ " :" ++ s)

--
-- Send a message out to the server we're currently connected to
--
write :: String -> String -> Net ()
write s t = do
    h <- asks socket
    io $ hPrintf h "%s %s\r\n" s t
    io $ printf    "> %s %s\n" s t

--
-- Convenience.
--
io :: IO a -> Net a
io = liftIO

type Pattern = String

type Action = String -> IO String

data Rule = Rule {
      pattern :: Pattern
    , action :: Action
}

instance Default Rule where
  def = Rule
          { pattern = ""
          , action  = def
          }

instance IsString Rule where
  fromString x = def { pattern = x}

liftAction :: Action -> String -> Net ()
liftAction a s = do
    h <- asks socket
    conf <- asks config

    r <- io (a s)
    p r h (chan conf)
        where
          p [] _ _ = return ()
          p r h c = io $ hPrintf h "PRIVMSG %s\r\n" (c ++ " :" ++ r)


newtype BehaviorM a = BehaviorM {unBehaviorM :: State [Rule] a}
    deriving (Functor
             , Applicative
             , Monad)

type Behavior = BehaviorM ()

instance Monoid a => Monoid (BehaviorM a) where
  mempty = return mempty
  mappend x y = x >> y

instance IsString Behavior where
  fromString = addRule . fromString

runBevhavior :: Behavior -> [Rule]
runBevhavior bev = execState (unBehaviorM bev) []

addRule :: Rule -> Behavior
addRule r = BehaviorM $ modify (r :)

modHeadRule :: Behavior -> (Rule -> Rule) -> Behavior
modHeadRule bev f = do
  let rs = runBevhavior bev
  BehaviorM $ case rs of
                x:_ -> modify (f x:)

ruleAddAction :: Action -> Rule -> Rule
ruleAddAction f r = r {action = f}

infixl 8 |!

(|!) :: Behavior -> (String -> IO String) -> Behavior
bev |! f = modHeadRule bev $ ruleAddAction f