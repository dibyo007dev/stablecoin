-- SPDX-FileCopyrightText: 2020 tqtezos
-- SPDX-License-Identifier: MIT
module Main
  ( main
  ) where

import Options.Applicative (execParser)
import qualified Unsafe (fromJust)

import Michelson.Runtime (prepareContract)
import Morley.Nettest
import Util.Named

import Lorentz.Contracts.Test.Common
import Nettest (scTransferScenario)

main :: IO ()
main = do
  let clientParser = clientConfigParser . pure $ Just "nettest.Stablecoin"
  parsedConfig <- execParser $
    parserInfo
      (#usage .! mempty)
      (#description .! "ManagedLedger nettest scenario")
      (#header .! "ManagedLedger nettest")
      (#parser .! clientParser)
  stablecoinContract <- prepareContract $ Just "test/resources/stablecoin.tz"
  let
    scenario :: NettestScenario
    scenario impl = do
      commentAction impl "Stablecoin contract nettest scenario"
      scTransferScenario (Unsafe.fromJust . mkInitialStorage) stablecoinContract impl

  env <- mkMorleyClientEnv parsedConfig
  runNettestViaIntegrational scenario
  runNettestClient env scenario
