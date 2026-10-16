-- | Private executable reserved for runtime qualification. EP-4 supplies commands.
module Main (main) where

main :: IO ()
main = ioError (userError "Runtime qualification driver is not implemented yet (EP-4).")
