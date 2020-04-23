module Test.Hooks.UseMemo where

import Prelude

import Data.Newtype (class Newtype)
import Data.Tuple.Nested ((/\))
import Halogen (liftAff)
import Halogen as H
import Halogen.Hooks (UseMemo, UseState)
import Halogen.Hooks as Hooks
import Halogen.Hooks.Internal.Eval.Types (InterpretHookReason(..))
import Test.Setup.Eval (evalM, mkEval)
import Test.Setup.Log (initDriver, logShouldBe, readResult, unsafeWriteLog)
import Test.Setup.Types (Hook', HookM', LogRef, MemoType(..), TestEvent(..))
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

newtype MemoHook h =
  MemoHook (UseMemo Int (UseMemo Int (UseMemo Int (UseState Int (UseState Int (UseState Int h))))))

derive instance newtypeMemoHook :: Newtype (MemoHook h) _

type MemoCount =
  { incrementA :: HookM' Unit
  , incrementB :: HookM' Unit
  , incrementC :: HookM' Unit
  , expensive1 :: Int
  , expensive2 :: Int
  , expensive3 :: Int
  }

useMemoCount :: LogRef -> Hook' MemoHook MemoCount
useMemoCount log = Hooks.wrap Hooks.do
  s1 /\ ts1 <- Hooks.useState 0
  s2 /\ ts2 <- Hooks.useState 0
  s3 /\ ts3 <- Hooks.useState 0

  expensive1 <- memoize1 { s1 }
  expensive2 <- memoize2 { s2 }
  expensive3 <- memoize3 { s1, s2 }

  Hooks.pure
    { incrementA: Hooks.modify_ ts1 (_ + 1) -- recomputes 1 and 3
    , incrementB: Hooks.modify_ ts2 (_ + 1) -- recomputes 2 and 3
    , incrementC: Hooks.modify_ ts3 (_ + 1) -- recomputes nothing
    , expensive1
    , expensive2
    , expensive3
    }
  where
  memoize1 deps@{ s1 } = Hooks.captures deps $ flip Hooks.useMemo \_ -> do
    let _ = unsafeWriteLog (RunMemo (CalculateMemo 1)) log
    s1 + 5

  memoize2 deps@{ s2 } = Hooks.captures deps $ flip Hooks.useMemo \_ -> do
    let _ = unsafeWriteLog (RunMemo (CalculateMemo 2)) log
    s2 + 5

  memoize3 deps@{ s1, s2 } = Hooks.captures deps $ flip Hooks.useMemo \_ -> do
    let _ = unsafeWriteLog (RunMemo (CalculateMemo 3)) log
    s1 + s2 + 5

memoHook :: Spec Unit
memoHook = before initDriver $ describe "useMemo" do
  let
    eval = mkEval useMemoCount

  it "initializes to the proper initial values" \ref -> do
    { expensive1, expensive2, expensive3 } <- evalM ref do
      eval $ H.tell H.Initialize
      liftAff $ readResult ref

    expensive1 `shouldEqual` 5
    expensive2 `shouldEqual` 5
    expensive3 `shouldEqual` 5

  it "recalculates memoized values in response to actions" \ref -> do
    { expensive1, expensive2, expensive3 } <- evalM ref do
      eval $ H.tell H.Initialize
      { incrementA, incrementB } <- liftAff $ readResult ref
      eval (H.tell $ H.Action incrementA) *> eval (H.tell $ H.Action incrementB)
      eval $ H.tell $ H.Finalize
      liftAff $ readResult ref

    expensive1 `shouldEqual` 6
    expensive2 `shouldEqual` 6
    expensive3 `shouldEqual` 7

    logShouldBe ref $
      [ RunHooks Initialize
      , RunMemo (CalculateMemo 1)
      , RunMemo (CalculateMemo 2)
      , RunMemo (CalculateMemo 3)
      , Render

        -- incrementA should recompute memos 1 and 3
      , ModifyState
      , RunHooks Step
      , RunMemo (CalculateMemo 1)
      , RunMemo (CalculateMemo 3)
      , Render

        -- incrementB should recompute memos 2 and 3
      , ModifyState
      , RunHooks Step
      , RunMemo (CalculateMemo 2)
      , RunMemo (CalculateMemo 3)
      , Render

      , RunHooks Finalize
      , Render
      ]

  it "does not recalculate memoized values when memos are unchanged" \ref -> do
    { expensive1, expensive2, expensive3 } <- evalM ref do
      eval $ H.tell H.Initialize
      { incrementC } <- liftAff $ readResult ref
      eval $ H.tell $ H.Action incrementC
      eval $ H.tell $ H.Finalize
      liftAff $ readResult ref

    expensive1 `shouldEqual` 5
    expensive2 `shouldEqual` 5
    expensive3 `shouldEqual` 5

    logShouldBe ref $
      [ RunHooks Initialize
      , RunMemo (CalculateMemo 1)
      , RunMemo (CalculateMemo 2)
      , RunMemo (CalculateMemo 3)
      , Render

        -- incrementC shouldn't affect memoized values
      , ModifyState
      , RunHooks Step
      , Render

      , RunHooks Finalize
      , Render
      ]
