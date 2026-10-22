{-# LANGUAGE OverloadedStrings #-}

-- | The shape of the witness set @admin sign-tx@ writes, pinned against both of its consumers.
--
-- __What the signer has to get right.__ Every write route on the interaction API returns an unsigned
-- transaction, @/submit-tx@ takes @{tx_unsigned, tx_wit}@, and @tx_wit@ is parsed by Atlas's
-- 'txWitFromHex': a witness SET, not a @cardano-cli@ text envelope and not a bare key witness.
-- @docs/deployment/attest-flow-smoke.md@ records why that distinction earns a test — a signer that
-- emits a nearly-right encoding fails at @/submit-tx@ on a live deployment, where it reads as a
-- protocol bug rather than as a signer bug.
--
-- __Why this is a unit test.__ A signature is a function of a transaction and a key, so neither case
-- needs a provider or an emulator: 'txFromHex' yields a 'GYTxBody' from a pinned transaction and
-- 'signingKeyFromRawBytesHex' yields a key from pinned bytes. @TestRuns@ obtains its bodies from
-- @buildTxBody@ inside @GYTxGameMonad@, and borrowing that would have bought nothing here — what a
-- body contains is irrelevant to the encoding of a signature over it.
--
-- __These cases test the command's own code, which took a three-line move to arrange.__ A cabal
-- test-suite cannot import an executable's modules, so while 'keyWitnessesOf' and 'txWitToHex' lived
-- in @src/exe/admin/Main.hs@ the only test available was one carrying COPIES of them — and a test
-- that pins a copy passes forever while the thing it is named after rots. They now live in
-- @offchain-lib@ beside 'signGYTxBody', which is both where they belong and what makes these
-- assertions mean something about @admin sign-tx@.
module UnitTests.SignTx (tests) where

import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import GeniusYield.Types
import Palmares.TxBuilding.Transactions (keyWitnessesOf, txWitToHex)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "sign-tx witness set"
    [ -- THE CASE THAT MAKES THE ENCODING RIGHT BY CONSTRUCTION. It walks the whole contract: sign
      -- the body the way the repo signs everything else, extract the witness set, hex-encode it,
      -- then hand that hex to the parser `tx_wit` uses and the function `handleSubmitTx` applies to
      -- the result. If the transaction that comes out is byte-identical to the one `signGYTxBody`
      -- built directly, then nothing was lost or added anywhere along the way.
      testCase "the hex a signer writes rebuilds exactly what signGYTxBody produces" $ do
        let body = getTxBody pinnedTx
            signed = signGYTxBody body [signingKey]
            hex = T.unpack (txWitToHex (keyWitnessesOf signed))
        case txWitFromHex hex of
          Nothing -> assertFailure ("tx_wit would refuse this witness set: " <> hex)
          Just wit -> txToHex (makeSignedTransaction wit body) @?= txToHex signed,
      -- And the extraction is the vkey witnesses and nothing else: ONE, the one `signGYTxBody`
      -- added. The pinned transaction arrives carrying a witness of its own, so this also records
      -- that `makeSignedTransaction` replaces a witness set rather than merging into it — which is
      -- what lets the case above be an equality at all.
      testCase "it is the vkey witnesses, and only the one that was just made" $
        length (txWitToKeyWitnessApi (keyWitnessesOf (signGYTxBody (getTxBody pinnedTx) [signingKey])))
          @?= 1,
      -- The shape, against a witness set a real CIP-30 wallet returned (Atlas's own documented
      -- `api.signTx` output, the example `attest-flow-smoke.md` quotes). Decoding and re-encoding it
      -- reproduces it byte for byte, which is the statement that this encoder emits a witness set in
      -- the wallet's form: a text envelope, a bare key witness or a case-shifted hex all fail here.
      testCase "a CIP-30 wallet's own witness set survives the encoder byte for byte" $
        (txWitToHex <$> txWitFromHex walletWitnessSetHex) @?= Just (T.pack walletWitnessSetHex)
    ]

------------------------------------------------------------------------------------------------

-- * Fixtures

------------------------------------------------------------------------------------------------

-- | A pinned payment key.
--
-- Any 32 bytes are a valid Ed25519 seed and nothing here depends on which: the transaction below
-- does not require this key's signature, and it is never submitted anywhere.
--
-- A plain payment key where the command uses the EXTENDED one a mnemonic derives, because the key's
-- nature does not reach the witness set: @makeShelleyKeyWitness@ casts an extended payment key down
-- and produces the same @WitVKey@, and pinning a valid 96-byte @xprv@ here would buy nothing.
signingKey :: GYPaymentSigningKey
signingKey =
  either error id $
    signingKeyFromRawBytesHex "5e3f0d6b8a1c47f2b9d0e6a3c85f71240b9e2d6a4c8f03b5e7a1d9c2f604b83e"

-- | A pinned Conway transaction — three inputs, three outputs, a fee, one witness, no scripts.
--
-- Taken from Atlas's own test suite (@GeniusYield.Test.Providers.Mashup@), where it is fed to the
-- same 'txFromHex' this uses, so it is a transaction this exact decoder is known to accept. A plain
-- payment on purpose: script, datum and redeemer witnesses are rebuilt from @tx_unsigned@ on the
-- far side and are no part of what a signer produces.
pinnedTx :: GYTx
pinnedTx =
  fromMaybe (error "UnitTests.SignTx: the pinned transaction no longer parses") (txFromHex pinnedTxHex)

pinnedTxHex :: String
pinnedTxHex =
  "84a30083825820cd1fd0900870f19cba004ad73996d5f01f22790c7e2efcd46b7d1bacbf97ca6d00825820cd1fd0900870f1\
  \9cba004ad73996d5f01f22790c7e2efcd46b7d1bacbf97ca6d01825820cd1fd0900870f19cba004ad73996d5f01f22790c7e\
  \2efcd46b7d1bacbf97ca6d020183a200581d6007fb2b78b3917d3f6bfa3a59de61f3c225cbf0d5564a1cbc6f96d6eb011a3b\
  \3b81d5a200581d6007fb2b78b3917d3f6bfa3a59de61f3c225cbf0d5564a1cbc6f96d6eb011a002dc6c0a200581d6007fb2b\
  \78b3917d3f6bfa3a59de61f3c225cbf0d5564a1cbc6f96d6eb011a001bc75b021a0002bd25a10081825820b8ee2dc03ba6f8\
  \8baa7e4430675df3e559d63a1282f7763de71227041e351023584020313e571def2f09145ae6b0eb26e99260d14885789929\
  \a354fea4a585d5f053fc2eae86d36f484269b0d95a25abb7acc3b15033565d00afd83af83f24d9be0ef5f6"

-- | A witness set as a CIP-30 wallet's @api.signTx@ returned it — one vkey witness, map key @0@.
--
-- Atlas documents this one against 'txWitFromHex' in @GeniusYield.Types.Tx@, and it is the form
-- @attest-flow-smoke.md@'s @a1008182582064…01@ example abbreviates.
walletWitnessSetHex :: String
walletWitnessSetHex =
  "a100818258206400a17ee58ce12a54c6edb7b964f0eb217e00dac75f2a47eccb6eedd02809a4584048bfa2dbf21514cafd14\
  \25b0072c67dd09cce82f5688169cff4761ca47e6557371ecc1ccbadde231dee179cf17d9dac29a61ac64ff9ef2dbd94968ec\
  \26301801"
