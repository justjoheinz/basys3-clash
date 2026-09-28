module Main (main) where

import Clash.Main (defaultMain)
import System.Environment (getArgs)

main :: IO ()
main = getArgs >>= defaultMain
