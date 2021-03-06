-- SPDX-FileCopyrightText: 2020 tqtezos
-- SPDX-License-Identifier: MIT

-- TODO: switch to `advanceTime` and remove this pragma when #350 is merged
-- https://gitlab.com/morley-framework/morley/-/issues/350
{-# OPTIONS_GHC -Wno-deprecations #-}
{-# OPTIONS_GHC -Wno-unused-do-bind #-}
{-# LANGUAGE PackageImports #-}

-- | Tests for permit functionality of stablecoin smart-contract

module Lorentz.Contracts.Test.Permit
  ( permitSpec
  ) where

import Test.Hspec (Spec, describe, it, specify)

import Lorentz (BigMap(..), TAddress, lPackValue, mkView, mt)
import Lorentz.Test
import Michelson.Runtime (ExecutorError)
import Michelson.Runtime.GState (GState(gsChainId), initGState)
import Tezos.Address (Address)
import Tezos.Crypto (PublicKey, SecretKey(..), Signature(..))
import qualified Tezos.Crypto.Ed25519 as Ed25519
import qualified Tezos.Crypto.Hash as Hash
import qualified Tezos.Crypto.P256 as P256
import qualified Tezos.Crypto.Secp256k1 as Secp256k1
import Tezos.Crypto.Util (deterministic)

import qualified "stablecoin" Lorentz.Contracts.Spec.FA2Interface as FA2
import Lorentz.Contracts.Stablecoin hiding (stablecoinContract)

import Lorentz.Contracts.Test.Common
import Lorentz.Contracts.Test.FA2 (fa2NotOperator, fa2NotOwner)
import Lorentz.Contracts.Test.Management
  (mgmNotContractOwner, mgmNotMasterMinter, mgmNotPauser, mgmNotPendingOwner)

sign :: SecretKey -> ByteString -> Signature
sign sk bs =
  case sk of
    SecretKeyEd25519 sk' -> SignatureEd25519 $ Ed25519.sign sk' bs
    SecretKeyP256 sk' -> SignatureP256 $ deterministic seed $ P256.sign sk' bs
    SecretKeySecp256k1 sk' -> SignatureSecp256k1 $ deterministic seed $ Secp256k1.sign sk' bs
  where
    seed = "abc"

mkPermit :: TAddress Parameter -> SecretKey -> Natural -> Parameter -> (PermitHash, ByteString, Signature)
mkPermit contractAddr sk counter param =
  let permitHash = mkPermitHash param
      toSign = lPackValue ((contractAddr, gsChainId initGState), (counter, permitHash))
      sig = sign sk toSign
  in  (permitHash, toSign, sig)

callPermit :: TAddress Parameter -> PublicKey -> SecretKey -> Natural -> Parameter -> IntegrationalScenarioM PermitHash
callPermit contractAddr pk sk counter param = do
  let (permitHash, _, sig) = mkPermit contractAddr sk counter param
  lCallEP contractAddr (Call @"Permit") $ PermitParam pk sig permitHash
  pure permitHash

errExpiredPermit, errNotPermitIssuer :: ExecutorError -> IntegrationalScenario
errExpiredPermit = lExpectFailWith (== [mt|EXPIRED_PERMIT|])
errNotPermitIssuer = lExpectFailWith (== [mt|NOT_PERMIT_ISSUER|])

errMissignedPermit :: ByteString -> ExecutorError -> IntegrationalScenario
errMissignedPermit signedBytes = lExpectFailWith (== ([mt|MISSIGNED|], signedBytes))

-- | Assert that there are n permits left in the storage
assertPermitCount :: TAddress Parameter -> Int -> IntegrationalScenario
assertPermitCount contractAddr expectedCount =
  lExpectStorage contractAddr $ \storage ->
    let count = permitCount (sPermits storage)
    in  if count == expectedCount
          then Right ()
          else Left $ CustomTestError $
                "Expected there to be "
                <> show expectedCount
                <> " permits left in the storage, but there were "
                <> show count
  where
    permitCount :: BigMap Address UserPermits -> Int
    permitCount (BigMap permits) =
      sum $
        permits <&> \userPermits -> length (upPermits userPermits)

permitSpec :: OriginationFn Parameter -> Spec
permitSpec originate = do
  describe "Permits" $ do
    specify "The counter used to sign the permit must match the contract's counter" $
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
          withSender testPauser $
            let
              (permitHash, _signedBytes, sig) = mkPermit stablecoinContract testPauserSK 999 Pause
              expectedSignedBytes = lPackValue ((stablecoinContract, gsChainId initGState), (0 :: Natural, permitHash))
            in
              lCallEP stablecoinContract (Call @"Permit") (PermitParam testPauserPK sig permitHash)
                `catchExpectedError` errMissignedPermit expectedSignedBytes

    specify "The public key must match the private key used to sign the permit" $
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
          withSender testPauser $
            let
              (permitHash, signedBytes, sig) = mkPermit stablecoinContract testPauserSK 0 Pause
            in
              lCallEP stablecoinContract (Call @"Permit") (PermitParam wallet1PK sig permitHash)
                `catchExpectedError` errMissignedPermit signedBytes

    specify "The permit can be sent to the contract by a user other than the signer" $
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
          withSender wallet1 $
            callPermit stablecoinContract testPauserPK testPauserSK 0 Pause

          withSender wallet2 $
            lCallEP stablecoinContract (Call @"Pause") ()

    specify "Admins do not consume permits" $
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do

          withSender testPauser $ do
            callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
            lCallEP stablecoinContract (Call @"Pause") ()
            lCallEP stablecoinContract (Call @"Unpause") ()
          withSender wallet1 $
            lCallEP stablecoinContract (Call @"Pause") ()

    specify "Counter is increased every time a permit is issued" $ do
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
          let issuePermit counter =
                void $ callPermit stablecoinContract testPauserPK testPauserSK counter Pause

          withSender testPauser $ do
            issuePermit 0
            issuePermit 1
            issuePermit 2
            issuePermit 3

    specify "`Unpause` permit cannot be used to pause" $
      -- More generally, we want to assert that if two entrypoints X and Y have the same
      -- parameter type (in this case, both `Pause` and `Unpause` are of type `Unit`),
      -- then a permit issued for X cannot be used to access entrypoint Y.
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
          withSender wallet2 $ do
            callPermit stablecoinContract testPauserPK testPauserSK 0 Unpause
            lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` mgmNotPauser

    specify "Permits expire after some time (set by the contract)" $ do
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
          let defaultExpiry = opDefaultExpiry defaultOriginationParams

          withSender testPauser $ do
            callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
          withSender wallet1 $ do
            rewindTime (fromIntegral defaultExpiry + 1)
            lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` errExpiredPermit

    specify "Re-uploading a permit hash resets its `created_at` timestamp" $ do
      integrationalTestExpectation $ do
        let defaultExpiry = 5
        let originationParams = defaultOriginationParams { opDefaultExpiry = defaultExpiry }
        withOriginated originate originationParams $ \stablecoinContract -> do
          withSender wallet1 $ do
            callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
            assertPermitCount stablecoinContract 1
            -- Advance 4 seconds, so the permit only has 1 second left until it expires
            rewindTime 4
            -- Re-upload permit hash
            callPermit stablecoinContract testPauserPK testPauserSK 1 Pause
            assertPermitCount stablecoinContract 1
            -- If the permit's `created_at` timestamp was reset (as expected),
            -- we should be able to advance 2 seconds and consume the permit.
            rewindTime 2
            lCallEP stablecoinContract (Call @"Pause") ()

    specify "Re-uploading a permit hash resets its `expiry` back to `None`" $ do
      integrationalTestExpectation $ do
        let defaultExpiry = 10
        let originationParams = defaultOriginationParams { opDefaultExpiry = defaultExpiry }
        withOriginated originate originationParams $ \stablecoinContract -> do
          withSender wallet1 $ do
            hash <- callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
            -- Set the permit's expiry to 3
            lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 3 (Just (hash, testPauser))
            -- Re-upload permit hash
            callPermit stablecoinContract testPauserPK testPauserSK 1 Pause
            assertPermitCount stablecoinContract 1
            -- If the permit's expiry was reset (as expected),
            -- we should be able to advance 4 seconds and consume the permit.
            rewindTime 4
            lCallEP stablecoinContract (Call @"Pause") ()

    specify "When a permit is issued, the issuer's expired permits are purged" $
      integrationalTestExpectation $ do
        withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
          let defaultExpiry = opDefaultExpiry defaultOriginationParams
          withSender testPauser $ do
            callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
            rewindTime (fromIntegral defaultExpiry + 1)
            callPermit stablecoinContract testPauserPK testPauserSK 1 Unpause
            assertPermitCount stablecoinContract 1

    describe "Revoke" $ do
      specify "a user can revoke their own permits" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              hash <- callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              lCallEP stablecoinContract (Call @"Revoke") [RevokeParam hash testPauser]

            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` mgmNotPauser

      specify "a user cannot revoke other users' permits" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            hash <- withSender testPauser $
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause

            withSender wallet1 $
              lCallEP stablecoinContract (Call @"Revoke") [RevokeParam hash testPauser] `catchExpectedError` errNotPermitIssuer

      specify "a user X can issue a permit allowing others to revoke X's permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            hash <- withSender testPauser $ do
              hash <- callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              callPermit stablecoinContract testPauserPK testPauserSK 1 (Revoke [RevokeParam hash testPauser])
              pure hash

            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Revoke") [RevokeParam hash testPauser]
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` mgmNotPauser

      specify "a user X cannot issue a permit allowing others to revoke Y's permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            hash <- withSender testPauser $ do
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause

            withSender wallet1 $
              callPermit stablecoinContract wallet1PK wallet1SK 1 (Revoke [RevokeParam hash testPauser])

            withSender wallet2 $ do
              lCallEP stablecoinContract (Call @"Revoke") [RevokeParam hash testPauser]
                `catchExpectedError` errNotPermitIssuer

      specify "permits for this entrypoint are consumed upon use" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            hash <- withSender testPauser $ do
              hash <- callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              callPermit stablecoinContract testPauserPK testPauserSK 1 (Revoke [RevokeParam hash testPauser])
              pure hash

            withSender wallet1 $ do
              assertPermitCount stablecoinContract 2
              lCallEP stablecoinContract (Call @"Revoke") [RevokeParam hash testPauser]
              assertPermitCount stablecoinContract 0

      it "can remove multiple permits at once" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              hash1 <- callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              hash2 <- callPermit stablecoinContract testPauserPK testPauserSK 1 Unpause
              lCallEP stablecoinContract (Call @"Revoke")
                [ RevokeParam hash1 testPauser
                , RevokeParam hash2 testPauser
                ]

            -- `wallet1` should now be unable to neither pause nor unpause the contract
            withSender wallet1 $
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` mgmNotPauser

            withSender testPauser $
              lCallEP stablecoinContract (Call @"Pause") ()

            withSender wallet1 $
              lCallEP stablecoinContract (Call @"Unpause") () `catchExpectedError` mgmNotPauser

      it "does nothing if the permit has already been consumed" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            hash <- withSender testPauser $
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause

            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Pause") ()

            withSender testPauser $
              lCallEP stablecoinContract (Call @"Revoke") [RevokeParam hash testPauser]

      it "does nothing if the permit never existed" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let hash = PermitHash (Hash.blake2b "abc")

            withSender testPauser $ do
              lCallEP stablecoinContract (Call @"Revoke") [RevokeParam hash testPauser]

    describe "Set_expiry" $ do
      it "anyone can set the expiry for a specific permit" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            hash <- withSender testPauser $
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause

            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 1 (Just (hash, testPauser))
              rewindTime 2
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` errExpiredPermit

      it "does not fail when permit does not exist" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let hash = PermitHash (Hash.blake2b "abc")
            lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 1 (Just (hash, testPauser))

      it "a user can set a default expiry for all permits signed with their secret key" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 1 Nothing
            withSender wallet1 $ do
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              rewindTime 2
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` errExpiredPermit

      it "a permit's expiry takes precedence over a user's default expiry" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              hash <- callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 5 (Just (hash, testPauser))
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 10 Nothing
            withSender wallet1 $ do
              rewindTime 6
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` errExpiredPermit

      it "overrides permit's previous expiry" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              hash <- callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 5 (Just (hash, testPauser))
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 3 (Just (hash, testPauser))
            withSender wallet1 $ do
              rewindTime 4
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` errExpiredPermit

      it "overrides user's previous expiry" $ do
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 5 Nothing
              lCallEP stablecoinContract (Call @"Set_expiry") $ SetExpiryParam 3 Nothing
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
            withSender wallet1 $ do
              rewindTime 4
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` errExpiredPermit

    describe "Get_default_expiry" $
      it "retrieves the contract's default expiry" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let defaultExpiry = opDefaultExpiry defaultOriginationParams

            consumer <- lOriginateEmpty @Expiry contractConsumer "consumer"
            lCallEP stablecoinContract (Call @"Get_default_expiry") (mkView () consumer)

            lExpectViewConsumerStorage consumer [defaultExpiry]

    describe "Get_counter" $
      it "retrieves the contract's current counter" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do

            consumer <- lOriginateEmpty @Natural contractConsumer "consumer"

            lCallEP stablecoinContract (Call @"Get_counter") (mkView () consumer)
            callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
            lCallEP stablecoinContract (Call @"Get_counter") (mkView () consumer)
            callPermit stablecoinContract testPauserPK testPauserSK 1 Pause
            lCallEP stablecoinContract (Call @"Get_counter") (mkView () consumer)

            lExpectViewConsumerStorage consumer [0, 1, 2]

    describe "Pause" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` mgmNotPauser
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              lCallEP stablecoinContract (Call @"Pause") ()
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the pauser" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 Pause
              lCallEP stablecoinContract (Call @"Pause") () `catchExpectedError` mgmNotPauser

      specify "pauser does not consume 'pause' permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              callPermit stablecoinContract testPauserPK testPauserSK 0 Pause
              lCallEP stablecoinContract (Call @"Pause") ()
              assertPermitCount stablecoinContract 1

    describe "Unpause" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              lCallEP stablecoinContract (Call @"Pause") ()
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Unpause") () `catchExpectedError` mgmNotPauser
              callPermit stablecoinContract testPauserPK testPauserSK 0 Unpause
              lCallEP stablecoinContract (Call @"Unpause") ()
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the pauser" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $
              lCallEP stablecoinContract (Call @"Pause") ()

            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 Unpause
              lCallEP stablecoinContract (Call @"Unpause") () `catchExpectedError` mgmNotPauser

      specify "pauser does not consume 'unpause' permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testPauser $ do
              callPermit stablecoinContract testPauserPK testPauserSK 0 Unpause
              lCallEP stablecoinContract (Call @"Pause") ()
              lCallEP stablecoinContract (Call @"Unpause") ()
              assertPermitCount stablecoinContract 1

    describe "Transfer_ownership" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Transfer_ownership") wallet2 `catchExpectedError` mgmNotContractOwner
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Transfer_ownership wallet2)
              lCallEP stablecoinContract (Call @"Transfer_ownership") wallet2
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the contract owner" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 (Transfer_ownership wallet2)
              lCallEP stablecoinContract (Call @"Transfer_ownership") wallet2 `catchExpectedError` mgmNotContractOwner

      specify "contract owner does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testOwner $ do
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Transfer_ownership wallet2)
              lCallEP stablecoinContract (Call @"Transfer_ownership") wallet2
              assertPermitCount stablecoinContract 1

    describe "Accept_ownership" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testOwner $
              lCallEP stablecoinContract (Call @"Transfer_ownership") wallet2
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Accept_ownership") () `catchExpectedError` mgmNotPendingOwner
              callPermit stablecoinContract wallet2PK wallet2SK 0 Accept_ownership
              lCallEP stablecoinContract (Call @"Accept_ownership") ()
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the pending owner" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testOwner $
              lCallEP stablecoinContract (Call @"Transfer_ownership") wallet2
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 Accept_ownership
              lCallEP stablecoinContract (Call @"Accept_ownership") () `catchExpectedError` mgmNotPendingOwner

      specify "pending owner does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testOwner $
              lCallEP stablecoinContract (Call @"Transfer_ownership") wallet2
            withSender wallet2 $ do
              callPermit stablecoinContract wallet2PK wallet2SK 0 Accept_ownership
              lCallEP stablecoinContract (Call @"Accept_ownership") ()
              assertPermitCount stablecoinContract 1

    describe "Change_master_minter" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Change_master_minter") wallet2 `catchExpectedError` mgmNotContractOwner
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Change_master_minter wallet2)
              lCallEP stablecoinContract (Call @"Change_master_minter") wallet2
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the contract owner" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 (Change_master_minter wallet2)
              lCallEP stablecoinContract (Call @"Change_master_minter") wallet2 `catchExpectedError` mgmNotContractOwner

      specify "contract owner does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testOwner $ do
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Change_master_minter wallet2)
              lCallEP stablecoinContract (Call @"Change_master_minter") wallet2
              assertPermitCount stablecoinContract 1

    describe "Change_pauser" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Change_pauser") wallet2 `catchExpectedError` mgmNotContractOwner
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Change_pauser wallet2)
              lCallEP stablecoinContract (Call @"Change_pauser") wallet2
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the contract owner" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 (Change_pauser wallet2)
              lCallEP stablecoinContract (Call @"Change_pauser") wallet2 `catchExpectedError` mgmNotContractOwner

      specify "contract owner does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testOwner $ do
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Change_pauser wallet2)
              lCallEP stablecoinContract (Call @"Change_pauser") wallet2
              assertPermitCount stablecoinContract 1

    describe "Set_transferlist" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Set_transferlist") Nothing `catchExpectedError` mgmNotContractOwner
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Set_transferlist Nothing)
              lCallEP stablecoinContract (Call @"Set_transferlist") Nothing
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the contract owner" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 (Set_transferlist Nothing)
              lCallEP stablecoinContract (Call @"Set_transferlist") Nothing `catchExpectedError` mgmNotContractOwner

      specify "contract owner does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testOwner $ do
              callPermit stablecoinContract testOwnerPK testOwnerSK 0 (Set_transferlist Nothing)
              lCallEP stablecoinContract (Call @"Set_transferlist") Nothing
              assertPermitCount stablecoinContract 1

    describe "Configure_minter" $ do
      let param = ConfigureMinterParam wallet1 Nothing 30

      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Configure_minter") param `catchExpectedError` mgmNotMasterMinter
              callPermit stablecoinContract testMasterMinterPK testMasterMinterSK 0 (Configure_minter param)
              lCallEP stablecoinContract (Call @"Configure_minter") param
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the master minter" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 (Configure_minter param)
              lCallEP stablecoinContract (Call @"Configure_minter") param `catchExpectedError` mgmNotMasterMinter

      specify "master minter does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testMasterMinter $ do
              callPermit stablecoinContract testMasterMinterPK testMasterMinterSK 0 (Configure_minter param)
              lCallEP stablecoinContract (Call @"Configure_minter") param
              assertPermitCount stablecoinContract 1

    describe "Remove_minter" $ do
      let minter = wallet2

      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testMasterMinter $
              lCallEP stablecoinContract (Call @"Configure_minter") $ ConfigureMinterParam minter Nothing 30

            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Remove_minter") minter `catchExpectedError` mgmNotMasterMinter
              callPermit stablecoinContract testMasterMinterPK testMasterMinterSK 0 (Remove_minter minter)
              lCallEP stablecoinContract (Call @"Remove_minter") minter
              assertPermitCount stablecoinContract 0

      it "cannot be accessed when permit is not signed by the master minter" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender wallet1 $ do
              callPermit stablecoinContract wallet1PK wallet1SK 0 (Remove_minter minter)
              lCallEP stablecoinContract (Call @"Remove_minter") minter `catchExpectedError` mgmNotMasterMinter

      specify "master minter does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            withSender testMasterMinter $
              lCallEP stablecoinContract (Call @"Configure_minter") $ ConfigureMinterParam minter Nothing 30

            withSender testMasterMinter $ do
              callPermit stablecoinContract testMasterMinterPK testMasterMinterSK 0 (Remove_minter minter)
              lCallEP stablecoinContract (Call @"Remove_minter") minter
              assertPermitCount stablecoinContract 1

    describe "Transfer" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let transferParams =
                  [ FA2.TransferParam wallet2 []
                  , FA2.TransferParam wallet2 []
                  ]

            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Transfer") transferParams `catchExpectedError` fa2NotOperator
              callPermit stablecoinContract wallet2PK wallet2SK 0
                (Call_FA2 $ FA2.Transfer transferParams)
              lCallEP stablecoinContract (Call @"Transfer") transferParams
              assertPermitCount stablecoinContract 0

      specify "A user X cannot sign a permit allowing other users to transfer tokens from user Y's account" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let transferParams =
                  [ FA2.TransferParam wallet2 []
                  , FA2.TransferParam wallet3 []
                  ]

            withSender wallet1 $ do
              callPermit stablecoinContract wallet2PK wallet2SK 0
                (Call_FA2 $ FA2.Transfer transferParams)
              lCallEP stablecoinContract (Call @"Transfer") transferParams `catchExpectedError` fa2NotOperator

      specify "transferring from own account does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let transferParams =
                  [ FA2.TransferParam wallet2 [] ]
            withSender wallet2 $ do
              callPermit stablecoinContract wallet2PK wallet2SK 0
                (Call_FA2 $ FA2.Transfer transferParams)
              lCallEP stablecoinContract (Call @"Transfer") transferParams
              assertPermitCount stablecoinContract 1

      specify "operators do not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let transferParams =
                  [ FA2.TransferParam wallet2 [] ]
            withSender wallet2 $ do
              callPermit stablecoinContract wallet2PK wallet2SK 0
                (Call_FA2 $ FA2.Transfer transferParams)
              lCallEP stablecoinContract (Call @"Update_operators")
                [FA2.Add_operator FA2.OperatorParam { opOwner = wallet2, opOperator = wallet3, opTokenId = 0 }]
            withSender wallet3 $ do
              lCallEP stablecoinContract (Call @"Transfer") transferParams
              assertPermitCount stablecoinContract 1

    describe "Update_operators" $ do
      it "can be accessed via a permit" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let params =
                  [ FA2.Add_operator FA2.OperatorParam { opOwner = wallet2, opOperator = wallet3, opTokenId = 0 }
                  , FA2.Remove_operator FA2.OperatorParam { opOwner = wallet2, opOperator = wallet4, opTokenId = 0 }
                  ]

            withSender wallet1 $ do
              lCallEP stablecoinContract (Call @"Update_operators") params `catchExpectedError` fa2NotOwner
              callPermit stablecoinContract wallet2PK wallet2SK 0
                (Call_FA2 $ FA2.Update_operators params)
              lCallEP stablecoinContract (Call @"Update_operators") params
              assertPermitCount stablecoinContract 0

      specify "A user X cannot sign a permit allowing other users to modify user Y's operators" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let params =
                  [ FA2.Add_operator FA2.OperatorParam { opOwner = wallet2, opOperator = wallet3, opTokenId = 0 }
                  , FA2.Remove_operator FA2.OperatorParam { opOwner = wallet3, opOperator = wallet4, opTokenId = 0 }
                  ]

            withSender wallet1 $ do
              callPermit stablecoinContract wallet2PK wallet2SK 0
                (Call_FA2 $ FA2.Update_operators params)
              lCallEP stablecoinContract (Call @"Update_operators") params `catchExpectedError` fa2NotOwner

      specify "updating own operators does not consume permits" $
        integrationalTestExpectation $ do
          withOriginated originate defaultOriginationParams $ \stablecoinContract -> do
            let params =
                  [ FA2.Add_operator FA2.OperatorParam { opOwner = wallet2, opOperator = wallet3, opTokenId = 0 } ]

            withSender wallet2 $ do
              callPermit stablecoinContract wallet2PK wallet2SK 0
                (Call_FA2 $ FA2.Update_operators params)
              lCallEP stablecoinContract (Call @"Update_operators") params
              assertPermitCount stablecoinContract 1
