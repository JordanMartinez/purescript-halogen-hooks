# Deep Dive Into the Internals

## Explaining "Stateful Logic" in English

Hooks solve the problem of "stateful logic," code that uses state but which doesn't directly render anything. The code might run effects, which ultimately rerender something, but rendering is not its primary goal.

We'll use the concept of a debouncer to further concretize this idea. A debouncer is an action that runs using the last value it received after it has not received a value for a specified amount of time. For example, let's consider a user who wants to use an auto-complete dropdown. The user types in some content, and the dropdown displays a list of options based on that content. Without a debouncer, we would update the list of options each time the user presses a key, even if the user will immediately press another key, thereby invalidating all of our work. If a user types the word, "apple," we will update the list five times, one for each letter, to our server. Only the last update actually mattered; the other four wasted resources.

This problem is solved by using a debouncer. Each time the user types a letter, we restart the countdown timer. Once the countdown timer ends, we calculate which items should be in the dropdown based on the content the user provided. If a user quickly types the word, "apple," we will recalculate this list once. The first four letters do not cause any recalculation because the countdown timer restarts. Once half a second has passed after the user types the "e," the list of options is recalculated.

With that in mind, what do we need to implement this debouncer logic? Without being verbose, we need two things. We need to store, get, and update state. We also need to run effects:
1. (state) the latest value received (e.g. the user's inputted search).
2. (effect) the action to run with the latest value (e.g. recalculating the list of options).
3. (state) whether the action is waiting for the initial value (countdown hasn't started) or next value (countdown has started) before it runs.

The three things above have nothing to do with rendering. It is simply "stateful logic," non-rendering code that requires state to work.

## The Problem: Components Lack "Same State Structure" Guarantees

Let's say you define a component called `Container`. `Container` is a parent component that renders a few other child components: `NavigationBar`, `Canvas`, and `Toolbar`. Each component has its own local state, but there is no guarantee that the state value used for all of them are the same. `Toolbar`'s state may be just an `Int` whereas `Canvas` may store an `Array Polygon` whereas `Container` may store `UserSettings`, a `Record` of various things. As a result, you cannot "get" `Toolbar`'s state value in the same way that you can "get" a `Polygon` inside `Canvas`' state value in the same way that you can get a value from inside `Container`'s `UserSettings` record. The same could be said for updating any of these values. While it is possible for all of these components to use the same state structure (e.g. use a `Record` for everything), no such guarantee exists.

Now, let's say we want to add a debouncer to each one of these components. Since the structure of each component's state is different, we cannot use the same implementation of `debouncer` for each component. Rather, we have to refactor each component's state to support what `debouncer` needs to function and then reimplement `debouncer` within that component. In short, "stateful logic" doesn't scale in a component-only world. Rather, one _must_ reinvent the wheel in each component.

However, if we lived in a world where "same state structure" guarantees were upheld, then we could get and update each one of the above state values using the same process. Therefore, we could reuse `debouncer` across each one of these components without having to rewire the component to allow room for it.

## The Solution: Supporting "Same State Structure" Guarantees

### Ways to Support "Same State Structure" Guarantees

So, how would we do that? We would need to update our state structure to abide by the following things:
- it can store 0 to many states of different types. The size of this "container" is however large or small we need it to be
- each individual state value can be uniquely identified via some key

At first glance, it seems like a `Record` would suffice. It can "grow" by adding a new label and labels can be guaranteed to be unique. This is what `halogen-select` and `halogen-formless` currently do. The underlying state for the component must be a `Record`.
However, `Record`s come with a number of disadvantages. First, they generally require using type-level programming via type class constraints to guarantee some of things. For example, `halogen-formless` needs to specify its own label to store its own state without the user being able to modify it. As a result, there are already names that the end-user cannot reuse, lest there be name clashes in the labels. Second, using heavy-weight type-level programming makes it harder to understand some compiler errors when things go wrong.

A better option is an `Array`. It can be as large or small as we need it to be. Once we create the array and make it immutable, its indices will always uniquely refer to the same element. Unlike `Record`s, this requires no type-level magic. Similar to `Record`s, the index can be given a name via a binding (e.g. `let nameOfIndex = ...`).

However, `Array`s do suffer from one problem: out-of-bound errors. If one attempts to read the 10th element in an array that only has two elements, one will get a runtime error. No problem! We'll just ensure we never refer to an invalid index. If we write a library, we can guarantee that, right?

### Guaranteeing Valid Indices Means Prohibiting Conditions and `case`ing

Not quite. Conditions screw that up. In the below examples, we can build an Array that has a varying number of elements within it depending on what the input is. Because the array may be different each time, the indices we would provide might refer to a different element later on:

```purescript
foo :: Int -> Array Int
foo x = if isEven x then [] else [x]
-- ^ in one case, the array has 0 elements;
--   in another it has 1 element.

bar :: SomeType -> Array String
bar = case _ of
  First -> []
  Second -> ["a", "b"]
  Third -> ["z", "d", "e", "f"]
  _ -> []
```

If only there was a way to prevent users from using conditions when building their `Array`.

### Prohibiting Conditions and `case`ing via Indexed Monads

Monads are an abstraction for "boilerplate-free sequential computation." In other words, they run multiple computations sequentially rather than in parallel. However, this sequential chain of computations is NOT required to run in a specific order. I could erroneously run the `getFoo` computation before I run the `createFoo` computation.
```purescript
createFoo :: forall m. Monad m => m Unit

getFoo :: forall m. Monad m => m Foo

runFoo :: forall m. Monad m => m Unit
runFoo = do
  getFoo -- throws runtime error! 'Foo' doesn't exist yet
  createFoo
```

Indexed monads provide a way to add this "order" restriction. "You _must_ run `createFoo` before you can ever run `getFoo`." It works by storing the "state" of the sequential computation at the type-level:
```purescript
data Monad computationOutput = Monad computationOutput

data IndexedMonad
  stateBeforeWeRunThisComputation
  stateAfterWeRunThisComputation
  computationOutput
  = Monad computationOutput

ibind :: forall before theseMustMatch after a
       . IndexedMonad before theseMustMatch a
      -> (a -> IndexedMonad theseMustMatch after b)
      -> IndexedMonad before after b

createFoo :: IndexedMonad FooDoesNotExist FooExists Unit

getFoo :: IndexedMonad FooExists FooExists Foo

example = IndexedMonad FooDoesNotExist FooExists Unit
example = Ix.do -- use `ibind` as `bind` here
  createFoo
  getFoo
```

If we ever switched these two statements, we would get a type unification error:
```purescript
thisFails = do
  getFoo
  createFoo

-- Could not match `FooExists` (i.e. `getFoo`'s stateAfterWeRunThisComputation')
-- with type `FooDoesNotExist` (i.e. `createFoo`'s stateBeforeWeRunThisComputation')
-- when evaluating the expression `ibind getFoo \_ -> createFoo`
```

Crucially, indexed monads' "state" type guarantees only one possible path forward. There are no "forks in the road" when one uses indexed monads. Thus, if one tried to do something like this, one would get a compiler error
```purescript
deleteFoo :: IndexedMonad FooExists FooDeleted Unit

createBar :: IndexedMonad FooExists FooAndBarExists Unit

thisFailsToo = do
  createFoo
  random <- randomInt 1 10
  if random < 5 then
    deleteFoo
  else
    createBar
```

While the output of `deleteFoo` and `createBar` are the same (i.e. `Unit`), the final state of the sequential computation is not. In one path, `Foo` was deleted. In another path, `Foo` was untouched and `Bar` was created.

### Building `Array`s with Always-Valid Indices via Indexed Monads

If this is how indexed monads work, is there a way to prevent one from using conditions or `case` statements when building their `Array`? Yes, if one uses a type-level "stack" for the indexed monad's type-level "state."

```purescript
data IxMonad stateBefore stateAfter output

addFirst :: IxMonad none (FirstPlus none) Unit

addSecond :: IxMonad (FirstPlus none) (SecondPlus (FirstPlus none)) Unit
```
... and so forth. Here's the end result: a type-level linked-list.
```purescript
desiredArray :: IxMonad none (SecondPlus (FirstPlus none)) (Array a)
desiredArray = do
  addFirst
  addSecond
```

In the above version, `addFirst`/`addSecond` both return `Unit`, which isn't helpful. At the very least, we could return the index of the element in the array:
```purescript
data IxMonad stateBefore stateAfter output

addFirst :: IxMonad none (FirstPlus none) Int

addSecond :: IxMonad (FirstPlus none) (SecondPlus (FirstPlus none)) Int

desiredArray :: IxMonad none (SecondPlus (FirstPlus none)) _
desiredArray = do
  indexToFirstElement <- addFirst
  indexToSecondElement <- addSecond
  -- Now we can guarantee that indices always refers to
  -- their corresponding element in the underlying `Array`.
```

Now, what would happen if we returned both the index to the element in the array AND the element itself? In that case, we would change the returned `Int` to `Tuple a Int` where the `a` corresponds to the type of element in the array. Our API would look something like this:
```purescript
addFirst :: IxMonad none (FirstPlus none) (Tuple a Int)

-- "a /\ b" is syntax sugar for "(Tuple a b)"
addSecond :: IxMonad (FirstPlus none) (SecondPlus (FirstPlus none)) (b /\ Int)

desiredApi :: IxMonad none allElements _
desiredApi = do
  first /\ firstIndex <- addFirst
  second /\ secondIndex <- addSecond
  -- ...
```

Let's make one more change. Right now, we don't specify what the value we are storing in the array will be. So, let's add an argument that indicates what the initial value should be for that index in the element. Remember, the underlying `Array` can only store values of the same type. So, we'll use `String` for the time being.
```purescript
addFirst
  :: String
  -> IxMonad none (FirstPlus none) (String /\ Int)

addSecond
  :: String
  -> IxMonad (FirstPlus none) (SecondPlus (FirstPlus none)) (String /\ Int)

desiredApi :: IxMonad none allElements _
desiredApi = do
  first /\ firstIndex <- addFirst "first"
  second /\ secondIndex <- addSecond "second"
  -- ...
```

Finally, let's unify `addFirst` and `addSecond` into one definition. We'll call it `useState`. In the above examples, we used the `FirstPlus` and `SecondPlus` names to help clarify what is going on in the types. We will now remove those. Here's what our code looks like now:
```purescript
data UseState state previous

useState
  :: String
  -> IxMonad previous (UseState String previous) (String /\ Int)

desiredApi
  :: IxMonad
      none
      (UseState {- second -} String -- top of stack
      (UseState {- first -} String
      none))                        -- bottom of stack
      _                             -- return value to be determined
desiredApi = do
  first /\ firstIndex <- useState "first"
  second /\ secondIndex <- useState "second"
  -- ...
```

Ouch... the `IxMonad` definition gets a bit hairy. Let's use a type alias to clarify what it is.
```purescript
type IxStateStack none =
   UseState {- second -} String -- top of stack
  (UseState {- first -}  String
   none
  )
desiredApi :: IxMonad none (IxStateStack none) _
desiredApi = do
  first /\ firstIndex <- useState "first"
  second /\ secondIndex <- useState "second"
  -- ...
```

## Integrating Array-Making Indexed-Monads into Halogen Components

This idea integrates into Halogen components by implementing a system, a number of individual pieces that work together to make this concept work. In this section's explanation, some things won't make sense until later.

### Making a Component's State an Array

So, how would we take this idea and integrate it into Halogen components? We'll start by making its `State` type an `Array`. Since we'll be storing more than just state here, we'll start with a `Record` where one of its fields is the `Array`:
```purescript
type HalogenComponentState a =
  { state :: Array a }
```
When the component is first created, we'll run our indexed monad computation to produce the initial array:
```purescript
templateComponent :: H.Component HH.HTML QueryType Input Message MonadType
templateComponent =
  H.mkComponent
    { initialState: \input ->
        let
          arrayOfStates = runIndexedMonadComputation desiredApi input
        in
          arrayOfStates
    , -- other labels
    }
```

### Rendering the Initial HTML using the Array

But wait! How then do we render the component's HTML? The trick is to change what the indexed monad "returns" in its computation. Currently, it returns the array. Below, we'll change it to return the actual HTML we want to render for the component. Thus, rather than "producing" an array of states, we use the indexed monad computation to build the desired HTML by utilizing our array of states. This will change our code to look like this:
```purescript
type HalogenComponentState a =
  { html :: H.ComponentHTML ActionType ChildSlots MonadType }

desiredApi
  :: IxMonad none (IxStateStack none) (H.ComponentHTML ActionType ChildSlots MonadType)
desiredApi = do
  first /\ firstIndex <- useState "first"
  second /\ secondIndex <- useState "second"
  pure $
    HH.div_
      [ HH.text $ "First is " <> show first <>
                  " and second is " <> show second <> "."
      ]

component :: H.Component HH.HTML QueryType Input Message MonadType
component =
  H.mkComponent
    { initialState: \input ->
        let
          html = runIndexedMonadComputation desiredApi input
        in
          html
    , render: \html -> html
    , -- other labels
    }
```

However, this change means we are no longer storing the `Array` in the component's `State` type. Ideally, we would have a `State` type that has both the `html` and `state` labels inside of it.
```purescript
type HalogenComponentState a =
  { html :: H.ComponentHTML ActionType ChildSlots MonadType
  , state :: Array a
  }

desiredApi
  :: IxMonad none (IxStateStack none) (H.ComponentHTML ActionType ChildSlots MonadType)
desiredApi = -- same as before

component :: H.Component HH.HTML QueryType Input Message MonadType
component =
  H.mkComponent
    { initialState: \input ->
        let
          record = runIndexedMonadComputation desiredApi input
        in
          record
    , render: \record -> record.html
    , -- other labels
    }
```

So, how do we fix that?

### Using a `Free`-based DSL for Constructing the Component's State

The trick is to use a domain-specific language (DSL) via the `Free` monad. Using `Free`, we can define an abstract syntax tree (AST) that we later interpret to produce the results we want. In other words, we write the `desiredApi` implementation using our `Free`-based language. Then, we interpret that AST, so that it produces the `Record` that has both the `html` and `state` labels:
```purescript
data LanguageF state a
  = UseState state (state /\ Int -> a)

useState :: forall a. a -> Free LanguageF (state /\ Int -> Unit)
useState initial = wrap $ UseState initial

interpretLanguageF :: LanguageF state ~> HalogenM _ _ _ m (Maybe a)
interpretLanguageF = case _ of
  UseState initialState reply -> do
    -- this implementation isn't correct
    -- but it gets the idea across
    st <- H.get
    H.put (st { state = st.state `snoc` initialState })

    -- Note: we use the length of the array before appending the current
    -- element to it to determine what its corresponding index is in the array.
    reply $ Just $ initialState /\ Array.length st.state

-- used in `H.mkComponent` record.
initialState :: forall input. input -> _ { html :: _, state :: Array String }
initialState _ = foldFree interpretLanguageF desiredApi
```

However, `Free` by itself isn't an indexed monad. So, we'll add our own wrapper around it that adds the index to it:
```purescript
newtype IxFree fAlgebra before after a = IxFree (Free fAlgebra a)

type OurIxMonad before after output = IxFree LanguageF before after output
```

## Supporting the Capacity to Change State

### Introducing the Concept of an "Evaluation Cycles"

So far, our rendered HTML is static; we can't change the state stored in our Array, so that it updates the HTML. In Halogen components, we would use `H.modify_ \state -> state + 1` to update state and cause our component to rerender. In this implementation, the HTML we render is "returned" in the `desiredApi` computation. So, we need to somehow change what the values bound by the names `first` and `second` are:
```purescript
desiredApi
  :: IxMonad none (IxStateStack none) (H.ComponentHTML ActionType ChildSlots MonadType)
desiredApi = do
  -- When this code is first run, `first` is "first"
  -- and `second` is "second". Thus, the HTML text says
  -- "First is first and second is second."
  --
  -- Let's say we change `first` to "newValue" somewhere else.
  -- Now, `first` in this computational context should be "newValue",
  -- so that the HTML text says "First is newValue and second is second."
  first /\ firstIndex <- useState "first"
  second /\ secondIndex <- useState "second"
  pure $
    HH.div_
      [ HH.text $ "First is " <> show first <>
                  " and second is " <> show second <> "."
      ]
```

This is where the array indices become relevant. Since we use indexed monads to prevent the end-user from writing conditional computations, `firstIndex` and `secondIndex` always refer to the same array index. Thus, we can use them to update the correct element in the array of states. Unlike our array-building computation, the state-modifying computation does not need to be run in a specific order. Adding that constraint is actually undesirable here. Therefore, we will use a normal non-indexed monad here rather than the indexed monad used to build our array of states.

So what kind of monad will this be? Since `Halogen` components use `HalogenM` to run their Action/Query code, this new monad will mirror the API provided by that monad. Most of the time, it will delegate its handlers to `HalogenM`. However, whenever a state modification is called (e.g. `H.put`, `H.modify_`), it will need to implement things in a special way.

In short, whenever a state modifcation occurs, we will do two things:
1. use the index provided in `desiredApi` to update the corresponding element in the array that is stored in the component's state.
2. reinterpret the `desiredApi` AST to update the corresponding value's binding in that context, so that the returned HTML is also updated (i.e. `first` now refers to the value "newValue", not the value "first").

This two-part process is called an "evaluation cycle."

### Step 1: Updating the Value in the Array

The implementation is relatively simple:
```purescript
modifyState :: Int -> (String -> String) -> HalogenM _ _ _ m Unit
modifyState arrayIndex modifier = do
  st <- H.get
  let
    oldValue = Array.unsafeGetAt arrayIndex st.state
    newValue = modifier oldValue
    arrayWithNewValue = Array.unsafeSetAt arrayIndex newValue st.state
  H.put (st { state = arrayWithNewValue })
```

### Step 2: Reinterpreting the AST on State Modifications

`desiredApi` is nothing more than an AST. We interpreted the AST to build our initial array of states. However, we can also interpret that same AST with a different intent: using the array we created previously to rerender the component with updated state values.

In other words, we add a new argument called `InterpretReason` to our code. If it's `Initialize`, we interpret the AST to build the state array. If it's `NotInitialize`, we update the state values in the context, so that the rendered HTML is up-to-date. However, we can no longer use the length of the `Array` to determine on which index we are when interpreting the AST. Thus, we need to add another label to our component's state type: `nextIndex :: Int`. The change appears below:
```purescript
-- Current (copied from above)
type HalogenComponentState a =
  { html :: H.ComponentHTML ActionType ChildSlots MonadType
  , state :: Array a
  }

interpretLanguageF :: LanguageF state ~> HalogenM _ _ _ m (Maybe a)
interpretLanguageF = case _ of
  UseState initialState reply -> do
    -- this implementation isn't correct
    -- but it gets the idea across
    st <- H.get
    H.put (st { state = st.state `snoc` initialState
              -- increment our index by 1, so that next `useState`
              -- refers to correct index
              , nextIndex = st.nextIndex + 1
              })
    reply $ Just $ initialState /\ st.nextIndex

initialState :: forall input. input -> _ { html :: _, state :: Array String }
initialState _ = foldFree interpretLanguageF desiredApi

-- New version: includes the interpretation reason as an argument
-- Current (copied from above)
type HalogenComponentState a =
  { html :: H.ComponentHTML ActionType ChildSlots MonadType
  , state :: Array a
  , nextIndex :: Int
  }

interpretLanguageF :: InterpretReason -> LanguageF state ~> HalogenM _ _ _ m (Maybe a)
interpretLanguageF reason = case _ of
  UseState initialState reply -> case reason of

    -- When given this reason, we create the array
    Initialize -> do
      -- this implementation isn't correct
      -- but it gets the idea across
      st <- H.get
      H.put (st { state = st.state `snoc` initialState })

      -- Note: we use the length of the array before appending the current
      -- element to it to determine what its corresponding index is in the array.
      reply $ Just $ initialState /\ Array.length st.state

    -- When given this reason, we update the binding to be the current value
    NotInitialize -> do
      st <- H.get
      let
        nextIndex =
          -- if this is the last `useState`, then set `nextIndex` back to 0
          -- so that future evaluation cycles will refer to the correct index.
          -- Otherwise, increment it to the next one.
          if length st.state == st.nextIndex + 1 then 0 else st.nextIndex + 1

        element = Array.unsafeIndexAt st.nextIndex st.state

      H.modify_ (st { nextIndex = nextIndex })
      reply $ Just $ element /\ st.nextIndex

initialState :: forall input. input -> _ { html :: _, state :: Array String }
initialState _ = foldFree (interpretLanguageF Initialize) desiredApi

updateState :: _ { html :: _, state :: Array String }
updateState = foldFree (interpretLanguageF NotInitialize) desiredApi
```

### Preventing Invalid and Unnecessary Renders

This two-part process creates a problem. Since the component's state is the following...
```purescript
type HalogenComponentState a =
  { html :: H.ComponentHTML ActionType ChildSlots MonadType
  , state :: Array a
  , nextIndex :: Int
  }
```

... then the first part of the evaluation cycle will update the array when we change the value for `first`. Since the component's state gets updated, Halogen will rerender the component. This is unnecessary and will do nothing. Recall that the component's `render` function just uses the HTML stored in the state. Since that hasn't yet changed after the first part of this cycle is finished, nothing visual changes. However, the computer will waste time and resources on diffing the virtual DOM, even if no change occurred.

Moreover, as we evaluate the second part of the evaluation cycle, we will be updating `nextIndex` quite frequently. Since that is a part of the component's state, that will also cause an unnecessary rerender.

In other words, we only want to rerender the component whenever the `html` label gets updated (i.e. at the end of an evaluation cycle), not when we are updating our state.

So, how do we prevent the wasteful and useless first-part render? We store the `Array` in a `Ref`. Since the `Ref` itself is immutable, we can't change it and cause the component to render anything new. However, we can change the contents inside of it. Thus, our state type for the component is now:
```purescript
type HalogenComponentState a =
  { html :: H.ComponentHTML ActionType ChildSlots MonadType
  , internal :: Ref { state :: Array a, nextIndex :: Int }
  }
```

### Supporting States of Different Types via Existential Types

So far, our state type has been the same: `a` in `Array a`. That's not realistic; real-world use cases will use a number of different types for their state. So, how do we get around this limitation?

Fortunately, Halogen targets the browser backend. JavaScript's `Array`s don't require the values inside of it to be of the same type. We'll exploit this while tricking the PureScript compiler into thinking that the underlying `Array` stores values of the same type. How? By using existential types.

Existential types are similar to OOP objects: you can't access the data "inside" the object; you can only use the object via the API it provides for you via methods/functions.

We'll change our `Array a` to `Array StateValue`. But what is `StateValue`? It's...
```purescript
-- Prevent pattern matching on this type since the compiler will not
-- know what it's real runtime representation is while the value
-- is coerced to this type.
foreign import data StateValue :: Type

toStateValue :: forall state. state -> StateValue
toStateValue = unsafeCoerce

fromStateValue :: forall state. StateValue -> state
fromStateValue = unsafeCoerce
```

While you might cringe at the use of `unsafeCoerce`, you'll see that its usage is actually safe.
```purescript
useState :: forall state. state -> UseState _
useState initialState = wrap $ UseState initialState' interface
  where
  initialState' :: StateValue
  initialState' = toStateValue initialState

  interface :: Tuple StateValue Int -> Tuple state Int
  interface (Tuple value index) = Tuple (fromStateValue value) index
```
Since both `toStateValue` and `fromStateValue` are used in the same definition, this is safe despite the usage of `unsafeCoerce`.

Thus, our component's `State` type is now:
```purescript
type HalogenComponentState a =
  { html :: H.ComponentHTML ActionType ChildSlots MonadType
  , internal :: Ref { state :: Array StateValue, nextIndex :: Int }
  }
```


- what values do we need to store?
    - state -> changes causes rerender
    - mutable references -> changes does not cause rerender
    - effects -> initialize and finalize
- updating Halogen components to use 'shared state structure' of an array: "state" becomes HTML we use when we render; "non-state" becomes the state we actually manipulate
- evaluation cycles: update state, then run effects
- adding dependencies: useTickEffect,
- finally, add in memos
    - memos -> state that is otherwise expensive to produce and which should not incur performance penalty due to frequent hook re-evaluations