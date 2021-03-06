{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{- |
Module      :  Data.WorldPeace.Union

Copyright   :  Dennis Gosnell 2017
License     :  BSD3

Maintainer  :  Dennis Gosnell (cdep.illabout@gmail.com)
Stability   :  experimental
Portability :  unknown

This module defines extensible sum-types.  This is similar to how
<https://hackage.haskell.org/package/vinyl vinyl> defines extensible records.

A large portion of the code from this module was taken from the
<https://hackage.haskell.org/package/union union> package.
-}

module Data.WorldPeace.Union
  (
  -- * Union
    Union(..)
  , union
  , catchesUnion
  , absurdUnion
  , umap
  , relaxUnion
  , unionRemove
  , unionHandle
  -- ** Optics
  , _This
  , _That
  -- ** Typeclasses
  , Nat(Z, S)
  , RIndex
  , ReturnX
  , UElem(..)
  , IsMember
  , Contains
  , Remove
  , ElemRemove
  -- * OpenUnion
  , OpenUnion
  , openUnion
  , fromOpenUnion
  , fromOpenUnionOr
  , openUnionPrism
  , openUnionLift
  , openUnionMatch
  , catchesOpenUnion
  , relaxOpenUnion
  , openUnionRemove
  , openUnionHandle
  -- * Setup code for doctests
  -- $setup
  ) where

import Control.Applicative ((<|>))
import Control.DeepSeq (NFData(rnf))
import Data.Aeson (FromJSON(parseJSON), ToJSON(toJSON), Value)
import Data.Aeson.Types (Parser)
import Data.Functor.Identity (Identity(Identity, runIdentity))
import Data.Kind (Constraint)
import Data.Proxy
import Data.Type.Bool (If)
import Data.Typeable (Typeable)
import GHC.TypeLits (ErrorMessage(..), TypeError)
import Text.Read (Read(readPrec), ReadPrec, (<++))

import Data.WorldPeace.Internal.Prism
  ( Prism
  , Prism'
  , iso
  , preview
  , prism
  , prism'
  , review
  )
import Data.WorldPeace.Product
  ( Product(Cons, Nil)
  , ToOpenProduct
  , ToProduct
  , tupleToOpenProduct
  , tupleToProduct
  )

-- $setup
-- >>> :set -XConstraintKinds
-- >>> :set -XDataKinds
-- >>> :set -XGADTs
-- >>> :set -XKindSignatures
-- >>> :set -XTypeOperators
-- >>> import Data.Text (Text)
-- >>> import Text.Read (readMaybe)
-- >>> import Data.Type.Equality ((:~:)(Refl))

------------------------
-- Type-level helpers --
------------------------

-- | A partial relation that gives the index of a value in a list.
--
-- ==== __Examples__
--
-- Find the first item:
--
-- >>> Refl :: RIndex String '[String, Int] :~: 'Z
-- Refl
--
-- Find the third item:
--
-- >>> Refl :: RIndex Char '[String, Int, Char] :~: 'S ('S 'Z)
-- Refl
type family RIndex (r :: k) (rs :: [k]) :: Nat where
  RIndex r (r ': rs) = 'Z
  RIndex r (s ': rs) = 'S (RIndex r rs)

-- | Text of the error message.
type NoElementError (r :: k) (rs :: [k]) =
          'Text "You require open sum type to contain the following element:"
    ':$$: 'Text "    " ':<>: 'ShowType r
    ':$$: 'Text "However, given list can store elements only of the following types:"
    ':$$: 'Text "    " ':<>: 'ShowType rs

-- | This type family checks whether @a@ is inside @as@ and produces
-- compile-time error if not.
type family CheckElemIsMember (a :: k) (as :: [k]) :: Constraint where
    CheckElemIsMember a as =
      If (Elem a as) (() :: Constraint) (TypeError (NoElementError a as))

-- | Type-level version of the 'elem' function.
--
-- >>> Refl :: Elem String '[Double, String, Char] :~: 'True
-- Refl
-- >>> Refl :: Elem String '[Double, Char] :~: 'False
-- Refl
type family Elem (x :: k) (xs :: [k]) :: Bool where
    Elem _ '[]       = 'False
    Elem x (x ': xs) = 'True
    Elem x (y ': xs) = Elem x xs

-- | Change a list of types into a list of functions that take the given type
-- and return @x@.
--
-- >>> Refl :: ReturnX Double '[String, Int] :~: '[String -> Double, Int -> Double]
-- Refl
--
-- Don't do anything with an empty list:
--
-- >>> Refl :: ReturnX Double '[] :~: '[]
-- Refl
type family ReturnX x as where
  ReturnX x (a ': as) = ((a -> x) ': ReturnX x as)
  ReturnX x '[] = '[]

-- | A mere approximation of the natural numbers. And their image as lifted by
-- @-XDataKinds@ corresponds to the actual natural numbers.
data Nat = Z | S !Nat

-- | This is a helpful 'Constraint' synonym to assert that @a@ is a member of
-- @as@.  You can see how it is used in functions like 'openUnionLift'.
type IsMember (a :: u) (as :: [u]) = (CheckElemIsMember a as, UElem a as (RIndex a as))

-- | A type family to assert that all of the types in a list are contained
-- within another list.
--
-- >>> Refl :: Contains '[String] '[String, Char] :~: (IsMember String '[String, Char], (() :: Constraint))
-- Refl
--
-- >>> Refl :: Contains '[] '[Int, Char] :~: (() :: Constraint)
-- Refl
type family Contains (as :: [k]) (bs :: [k]) :: Constraint where
  Contains '[] _ = ()
  Contains (a ': as) bs = (IsMember a bs, Contains as bs)

-----------------------------
-- Union (from Data.Union) --
-----------------------------

-- | A 'Union' is parameterized by a universe @u@, an interpretation @f@
-- and a list of labels @as@. The labels of the union are given by
-- inhabitants of the kind @u@; the type of values at any label @a ::
-- u@ is given by its interpretation @f a :: *@.
--
-- What does this mean in practice?  It means that a type like
-- @'Union' 'Identity' \'['String', 'Int']@ can be _either_ an
-- @'Identity' 'String'@ or an @'Identity' 'Int'@.
--
-- You need to pattern match on the 'This' and 'That' constructors to figure
-- out whether you are holding a 'String' or 'Int':
--
-- >>> let u = That (This (Identity 1)) :: Union Identity '[String, Int]
-- >>> :{
--   case u of
--     This (Identity str) -> "we got a string: " ++ str
--     That (This (Identity int)) -> "we got an int: " ++ show int
-- :}
-- "we got an int: 1"
--
-- There are multiple functions that let you perform this pattern matching
-- easier: 'union', 'catchesUnion', 'unionMatch'
--
-- There is also a type synonym 'OpenUnion' for the common case of
-- @'Union' 'Indentity'@, as well as helper functions for working with it.
data Union (f :: u -> *) (as :: [u]) where
  This :: !(f a) -> Union f (a ': as)
  That :: !(Union f as) -> Union f (a ': as)
  deriving (Typeable)

-- | Case analysis for 'Union'.
--
-- See 'unionHandle' for a more flexible version of this.
--
-- ==== __Examples__
--
--  Here is an example of matching on a 'This':
--
-- >>> let u = This (Identity "hello") :: Union Identity '[String, Int]
-- >>> let runIdent = runIdentity :: Identity String -> String
-- >>> union (const "not a String") runIdent u
-- "hello"
--
-- Here is an example of matching on a 'That':
--
-- >>> let v = That (This (Identity 3.5)) :: Union Identity '[String, Double, Int]
-- >>> union (const "not a String") runIdent v
-- "not a String"
union :: (Union f as -> c) -> (f a -> c) -> Union f (a ': as) -> c
union _ onThis (This a) = onThis a
union onThat _ (That u) = onThat u

-- | Since a union with an empty list of labels is uninhabited, we
-- can recover any type from it.
absurdUnion :: Union f '[] -> a
absurdUnion u = case u of {}

-- | Map over the interpretation @f@ in the 'Union'.
--
-- ==== __Examples__
--
-- Here is an example of changing a @'Union' 'Identity' \'['String', 'Int']@ to
-- @'Union' 'Maybe' \'['String', 'Int']@:
--
-- >>> let u = This (Identity "hello") :: Union Identity '[String, Int]
-- >>> umap (Just . runIdentity) u :: Union Maybe '[String, Int]
-- Just "hello"
umap :: (forall a . f a -> g a) -> Union f as -> Union g as
umap f (This a) = This $ f a
umap f (That u) = That $ umap f u

catchesUnionProduct
  :: forall x f as.
     Applicative f
  => Product f (ReturnX x as) -> Union f as -> f x
catchesUnionProduct (Cons f _) (This a) = f <*> a
catchesUnionProduct (Cons _ p) (That u) = catchesUnionProduct p u
catchesUnionProduct Nil _ = undefined

-- | An alternate case anaylsis for a 'Union'.  This method uses a tuple
-- containing handlers for each potential value of the 'Union'.  This is
-- somewhat similar to the 'Control.Exception.catches' function.
--
-- ==== __Examples__
--
-- Here is an example of handling a 'Union' with two possible values.  Notice
-- that a normal tuple is used:
--
-- >>> let u = This $ Identity 3 :: Union Identity '[Int, String]
-- >>> let intHandler = (Identity $ \int -> show int) :: Identity (Int -> String)
-- >>> let strHandler = (Identity $ \str -> str) :: Identity (String -> String)
-- >>> catchesUnion (intHandler, strHandler) u :: Identity String
-- Identity "3"
--
-- Given a 'Union' like @'Union' 'Identity' \'['Int', 'String']@, the type of
-- 'catchesUnion' becomes the following:
--
-- @
--   'catchesUnion'
--     :: ('Identity' ('Int' -> 'String'), 'Identity' ('String' -> 'String'))
--     -> 'Union' 'Identity' \'['Int', 'String']
--     -> 'Identity' 'String'
-- @
--
-- Checkout 'catchesOpenUnion' for more examples.
catchesUnion
  :: (Applicative f, ToProduct tuple f (ReturnX x as))
  => tuple -> Union f as -> f x
catchesUnion tuple u = catchesUnionProduct (tupleToProduct tuple) u

-- | Relaxes a 'Union' to a larger set of types.
--
-- Note that the result types have to completely contain the input types.
--
-- >>> let u = This (Identity 3.5) :: Union Identity '[Double, String]
-- >>> relaxUnion u :: Union Identity '[Char, Double, Int, String, Float]
-- Identity 3.5
--
-- The original types can be in a different order in the result 'Union':
--
-- >>> let u = That (This (Identity 3.5)) :: Union Identity '[String, Double]
-- >>> relaxUnion u :: Union Identity '[Char, Double, Int, String, Float]
-- Identity 3.5
relaxUnion :: Contains as bs => Union f as -> Union f bs
relaxUnion (This as) = unionLift as
relaxUnion (That u) = relaxUnion u

-- | Lens-compatible 'Prism' for 'This'.
--
-- ==== __Examples__
--
-- Use '_This' to construct a 'Union':
--
-- >>> review _This (Just "hello") :: Union Maybe '[String]
-- Just "hello"
--
-- Use '_This' to try to destruct a 'Union' into a @f a@:
--
-- >>> let u = This (Identity "hello") :: Union Identity '[String, Int]
-- >>> preview _This u :: Maybe (Identity String)
-- Just (Identity "hello")
--
-- Use '_This' to try to destruct a 'Union' into a @f a@ (unsuccessfully):
--
-- >>> let v = That (This (Identity 3.5)) :: Union Identity '[String, Double, Int]
-- >>> preview _This v :: Maybe (Identity String)
-- Nothing
_This :: Prism (Union f (a ': as)) (Union f (b ': as)) (f a) (f b)
_This = prism This (union (Left . That) Right)
{-# INLINE _This #-}

-- | Lens-compatible 'Prism' for 'That'.
--
-- ==== __Examples__
--
-- Use '_That' to construct a 'Union':
--
-- >>> let u = This (Just "hello") :: Union Maybe '[String]
-- >>> review _That u :: Union Maybe '[Double, String]
-- Just "hello"
--
-- Use '_That' to try to peel off a 'That' from a 'Union':
--
-- >>> let v = That (This (Identity "hello")) :: Union Identity '[Int, String]
-- >>> preview _That v :: Maybe (Union Identity '[String])
-- Just (Identity "hello")
--
-- Use '_That' to try to peel off a 'That' from a 'Union' (unsuccessfully):
--
-- >>> let w = This (Identity 3.5) :: Union Identity '[Double, String]
-- >>> preview _That w :: Maybe (Union Identity '[String])
-- Nothing
_That :: Prism (Union f (a ': as)) (Union f (a ': bs)) (Union f as) (Union f bs)
_That = prism That (union Right (Left . This))
{-# INLINE _That #-}

------------------
-- type classes --
------------------

-- | @'UElem' a as i@ provides a way to potentially get an @f a@ out of a
-- @'Union' f as@ ('unionMatch').  It also provides a way to create a
-- @'Union' f as@ from an @f a@ ('unionLift').
--
-- This is safe because of the 'RIndex' contraint. This 'RIndex' constraint
-- tells us that there /actually is/ an @a@ in @as@ at index @i@.
--
-- As an end-user, you should never need to implement an additional instance of
-- this typeclass.
class i ~ RIndex a as => UElem (a :: k) (as :: [k]) (i :: Nat) where
  {-# MINIMAL unionPrism | (unionLift, unionMatch) #-}

  -- | This is implemented as @'prism'' 'unionLift' 'unionMatch'@.
  unionPrism :: Prism' (Union f as) (f a)
  unionPrism = prism' unionLift unionMatch

  -- | This is implemented as @'review' 'unionPrism'@.
  unionLift :: f a -> Union f as
  unionLift = review unionPrism

  -- | This is implemented as @'preview' 'unionPrism'@.
  unionMatch :: Union f as -> Maybe (f a)
  unionMatch = preview unionPrism

instance UElem a (a ': as) 'Z where
  unionPrism :: Prism' (Union f (a ': as)) (f a)
  unionPrism = _This
  {-# INLINE unionPrism #-}

instance
    ( RIndex a (b ': as) ~ ('S i)
    , UElem a as i
    )
    => UElem a (b ': as) ('S i) where

  unionPrism :: Prism' (Union f (b ': as)) (f a)
  unionPrism = _That . unionPrism
  {-# INLINE unionPrism #-}

-- | This type family removes a type from a type-level list.
--
-- This is used to compute the type of the returned 'Union' in 'unionRemove'.
--
-- ==== __Examples__
--
-- >>> Refl :: Remove Double '[Double, String] :~: '[String]
-- Refl
--
-- If the list contains multiple of the type, then they are all removed.
--
-- >>> Refl :: Remove Double '[Char, Double, String, Double] :~: '[Char, String]
-- Refl
--
-- If the list is empty, then nothing is removed.
--
-- >>> Refl :: Remove Double '[] :~: '[]
-- Refl
type family Remove (a :: k) (as :: [k]) :: [k] where
  Remove a '[] = '[]
  Remove a (a ': xs) = Remove a xs
  Remove a (b ': xs) = b ': Remove a xs

-- | This is used internally to figure out which instance to pick for the
-- 'ElemRemove\'' type class.
--
-- This is needed to work around overlapping instances.
--
-- >>> Refl :: RemoveCase Double '[Double, String] :~: 'CaseFirstSame
-- Refl
--
-- >>> Refl :: RemoveCase Double '[Char, Double, Double] :~: 'CaseFirstDiff
-- Refl
--
-- >>> Refl :: RemoveCase Double '[] :~: 'CaseEmpty
-- Refl
type family RemoveCase (a :: k) (as :: [k]) :: Cases where
  RemoveCase a '[] = 'CaseEmpty
  RemoveCase a (a ': xs) = 'CaseFirstSame
  RemoveCase a (b ': xs) = 'CaseFirstDiff

-- | This type alias is a 'Constraint' that is used when working with
-- functions like 'unionRemove' or 'unionHandle'.
--
-- 'ElemRemove' gives you a way to specific types from a 'Union'.
--
-- Note that @'ElemRemove' a as@ doesn't force @a@ to be in @as@.  We are able
-- to use 'unionRemove' to try to pull out a 'String' from a
-- @'Union' 'Identity' \'['Double']@ (even though there is no way this 'Union'
-- could contain a 'String'):
--
-- >>> let u = This (Identity 3.5) :: Union Identity '[Double]
-- >>> unionRemove u :: Either (Union Identity '[Double]) (Identity String)
-- Left (Identity 3.5)
--
-- When writing your own functions using 'unionRemove', in order to make sure
-- the @a@ is in @as@, you should combine 'ElemRemove' with 'IsMember'.
--
-- 'ElemRemove' uses some tricks to work correctly, so the underlying 'ElemRemove\''typeclass
-- is not exported.
type ElemRemove a as = ElemRemove' a as (RemoveCase a as)

-- | This function allows you to try to remove individual types from a 'Union'.
--
-- This can be used to handle only certain types in a 'Union', instead of
-- having to handle all of them at the same time.
--
-- ==== __Examples__
--
-- Handling a type in a 'Union':
--
-- >>> let u = This (Identity "hello") :: Union Identity '[String, Double]
-- >>> unionRemove u :: Either (Union Identity '[Double]) (Identity String)
-- Right (Identity "hello")
--
-- Failing to handle a type in a 'Union':
--
-- >>> let u = That (This (Identity 3.5)) :: Union Identity '[String, Double]
-- >>> unionRemove u :: Either (Union Identity '[Double]) (Identity String)
-- Left (Identity 3.5)
--
-- Note that if you have a 'Union' with multiple of the same type, they will
-- all be handled at the same time:
--
-- >>> let u = That (This (Identity 3.5)) :: Union Identity '[String, Double, Char, Double]
-- >>> unionRemove u :: Either (Union Identity '[String, Char]) (Identity Double)
-- Right (Identity 3.5)
unionRemove
  :: forall a as f
   . ElemRemove a as
  => Union f as
  -> Either (Union f (Remove a as)) (f a)
unionRemove = unionRemove' (Proxy @(RemoveCase a as))
{-# INLINE unionRemove #-}

-- | This is used as a promoted data type to give a tag to the three different
-- instances of 'ElemRemove\''.  These also correspond to the three different
-- cases of 'Remove' and 'RemoveCase'.
data Cases = CaseEmpty | CaseFirstSame | CaseFirstDiff

-- | This is an internal typeclass used for removing elements from a 'Union'.
--
-- The most surprising thing about this is the last argument, @caseMatch@.
-- This is used to stop GHC from seeing overlapping instances:
--
-- https://kseo.github.io/posts/2017-02-05-avoid-overlapping-instances-with-closed-type-families.html
--
-- Each of the instances of this correspond to one case in 'Remove' and
-- 'RemoveCase'.
class ElemRemove' (a :: k) (as :: [k]) (caseMatch :: Cases) where
  unionRemove' :: Proxy caseMatch -> Union f as -> Either (Union f (Remove a as)) (f a)

instance ElemRemove' a '[] 'CaseEmpty where
  unionRemove'
    :: Proxy 'CaseEmpty -> Union f '[] -> Either (Union f '[]) (f a)
  unionRemove' _ u = absurdUnion u
  {-# INLINE unionRemove' #-}

instance
    ( ElemRemove' a xs (RemoveCase a xs)
    ) =>
    ElemRemove' a (a ': xs) 'CaseFirstSame where
  unionRemove'
    :: forall f
     . Proxy 'CaseFirstSame
    -> Union f (a ': xs)
    -> Either (Union f (Remove a xs)) (f a)
  unionRemove' _ (This a) = Right a
  unionRemove' _ (That u) = unionRemove' (Proxy @(RemoveCase a xs)) u

instance
    ( ElemRemove' a xs (RemoveCase a xs)
    , -- We need to specify this equality because GHC doesn't realize it will
      -- always work out this way.  We know that for this case, @a@ and @b@
      -- will always be different (because of how the 'RemoveCase' type family
      -- works and the fact that there is already another instance that handles
      -- the case when @a@ and @b@ are the same type).
      --
      -- However, GHC doesn't realize this, so we have to specify it.
      Remove a (b ': xs) ~ (b ': Remove a xs)
    ) =>
    ElemRemove' a (b ': xs) 'CaseFirstDiff where
  unionRemove'
    :: forall f
     . Proxy 'CaseFirstDiff
    -> Union f (b ': xs)
    -> Either (Union f (b ': Remove a xs)) (f a)
  unionRemove' _ (This b) = Left (This b)
  unionRemove' _ (That u) =
    case unionRemove' (Proxy @(RemoveCase a xs)) u of
      Right fa -> Right fa
      Left u2 -> Left (That u2)

-- | Handle a single case on a 'Union'.  This is similar to 'union' but lets
-- you handle any case within the 'Union'.
--
-- ==== __Examples__
--
-- Handling the first item in a 'Union'.
--
-- >>> let u = This 3.5 :: Union Identity '[Double, Int]
-- >>> let printDouble = print :: Identity Double -> IO ()
-- >>> let printUnion = print :: Union Identity '[Int] -> IO ()
-- >>> unionHandle printUnion printDouble u
-- Identity 3.5
--
-- Handling a middle item in a 'Union'.
--
-- >>> let u2 = That (This 3.5) :: Union Identity '[Char, Double, Int]
-- >>> let printUnion = print :: Union Identity '[Char, Int] -> IO ()
-- >>> unionHandle printUnion printDouble u2
-- Identity 3.5
--
-- If you have duplicates in your 'Union', they will both get handled with
-- a single call to 'unionHandle'.
--
-- >>> let u3 = That (This 3.5) :: Union Identity '[Double, Double, Int]
-- >>> let printUnion = print :: Union Identity '[Int] -> IO ()
-- >>> unionHandle printUnion printDouble u3
-- Identity 3.5
--
-- Use 'absurdUnion' to handle an empty 'Union'.
--
-- >>> let u4 = This 3.5 :: Union Identity '[Double]
-- >>> unionHandle (absurdUnion :: Union Identity '[] -> IO ()) printDouble u4
-- Identity 3.5
unionHandle
  :: ElemRemove a as
  => (Union f (Remove a as) -> b)
  -> (f a -> b)
  -> Union f as
  -> b
unionHandle unionHandler aHandler u =
  either unionHandler aHandler $ unionRemove u

---------------
-- OpenUnion --
---------------

-- | We can use @'Union' 'Identity'@ as a standard open sum type.
--
-- See the documentation for 'Union'.
type OpenUnion = Union Identity

-- | Case analysis for 'OpenUnion'.
--
-- ==== __Examples__
--
--  Here is an example of successfully matching:
--
-- >>> let string = "hello" :: String
-- >>> let o = openUnionLift string :: OpenUnion '[String, Int]
-- >>> openUnion (const "not a String") id o
-- "hello"
--
-- Here is an example of unsuccessfully matching:
--
-- >>> let double = 3.5 :: Double
-- >>> let p = openUnionLift double :: OpenUnion '[String, Double, Int]
-- >>> openUnion (const "not a String") id p
-- "not a String"
openUnion
  :: (OpenUnion as -> c) -> (a -> c) -> OpenUnion (a ': as) -> c
openUnion onThat onThis = union onThat (onThis . runIdentity)

-- | This is similar to 'fromMaybe' for an 'OpenUnion'.
--
-- ==== __Examples__
--
--  Here is an example of successfully matching:
--
-- >>> let string = "hello" :: String
-- >>> let o = openUnionLift string :: OpenUnion '[String, Int]
-- >>> fromOpenUnion (const "not a String") o
-- "hello"
--
-- Here is an example of unsuccessfully matching:
--
-- >>> let double = 3.5 :: Double
-- >>> let p = openUnionLift double :: OpenUnion '[String, Double, Int]
-- >>> fromOpenUnion (const "not a String") p
-- "not a String"
fromOpenUnion
  :: (OpenUnion as -> a) -> OpenUnion (a ': as) -> a
fromOpenUnion onThat = openUnion onThat id

-- | Flipped version of 'fromOpenUnion'.
fromOpenUnionOr
  :: OpenUnion (a ': as) -> (OpenUnion as -> a) -> a
fromOpenUnionOr = flip fromOpenUnion

-- | Just like 'unionPrism' but for 'OpenUnion'.
openUnionPrism
  :: forall a as.
     IsMember a as
  => Prism' (OpenUnion as) a
openUnionPrism = unionPrism . iso runIdentity Identity
{-# INLINE openUnionPrism #-}

-- | Just like 'unionLift' but for 'OpenUnion'.
--
-- ==== __Examples__
--
-- Creating an 'OpenUnion':
--
-- >>> let string = "hello" :: String
-- >>> openUnionLift string :: OpenUnion '[Double, String, Int]
-- Identity "hello"
--
-- You will get a compile error if you try to create an 'OpenUnion' that
-- doesn't contain the type:
--
-- >>> let float = 3.5 :: Float
-- >>> openUnionLift float :: OpenUnion '[Double, Int]
-- ...
--     • You require open sum type to contain the following element:
--           Float
--       However, given list can store elements only of the following types:
--           '[Double, Int]
-- ...
openUnionLift
  :: forall a as.
     IsMember a as
  => a -> OpenUnion as
openUnionLift = review openUnionPrism

-- | Just like 'unionMatch' but for 'OpenUnion'.
--
-- ==== __Examples__
--
-- Successful matching:
--
-- >>> let string = "hello" :: String
-- >>> let o = openUnionLift string :: OpenUnion '[Double, String, Int]
-- >>> openUnionMatch o :: Maybe String
-- Just "hello"
--
-- Failure matching:
--
-- >>> let double = 3.5 :: Double
-- >>> let p = openUnionLift double :: OpenUnion '[Double, String]
-- >>> openUnionMatch p :: Maybe String
-- Nothing
--
-- You will get a compile error if you try to pull out an element from
-- the 'OpenUnion' that doesn't exist within it.
--
-- >>> let o2 = openUnionLift double :: OpenUnion '[Double, Char]
-- >>> openUnionMatch o2 :: Maybe Float
-- ...
--     • You require open sum type to contain the following element:
--           Float
--       However, given list can store elements only of the following types:
--           '[Double, Char]
-- ...
openUnionMatch
  :: forall a as.
     IsMember a as
  => OpenUnion as -> Maybe a
openUnionMatch = preview openUnionPrism

-- | An alternate case anaylsis for an 'OpenUnion'.  This method uses a tuple
-- containing handlers for each potential value of the 'OpenUnion'.  This is
-- somewhat similar to the 'Control.Exception.catches' function.
--
-- When working with large 'OpenUnion's, it can be easier to use
-- 'catchesOpenUnion' than 'openUnion'.
--
-- ==== __Examples__
--
-- Here is an example of handling an 'OpenUnion' with two possible values.
-- Notice that a normal tuple is used:
--
-- >>> let u = openUnionLift (3 :: Int) :: OpenUnion '[Int, String]
-- >>> let intHandler = (\int -> show int) :: Int -> String
-- >>> let strHandler = (\str -> str) :: String -> String
-- >>> catchesOpenUnion (intHandler, strHandler) u :: String
-- "3"
--
-- Given an 'OpenUnion' like @'OpenUnion' \'['Int', 'String']@, the type of
-- 'catchesOpenUnion' becomes the following:
--
-- @
--   'catchesOpenUnion'
--     :: ('Int' -> x, 'String' -> x)
--     -> 'OpenUnion' \'['Int', 'String']
--     -> x
-- @
--
-- Here is an example of handling an 'OpenUnion' with three possible values:
--
-- >>> let u = openUnionLift ("hello" :: String) :: OpenUnion '[Int, String, Double]
-- >>> let intHandler = (\int -> show int) :: Int -> String
-- >>> let strHandler = (\str -> str) :: String -> String
-- >>> let dblHandler = (\dbl -> "got a double") :: Double -> String
-- >>> catchesOpenUnion (intHandler, strHandler, dblHandler) u :: String
-- "hello"
--
-- Here is an example of handling an 'OpenUnion' with only one possible value.
-- Notice how a tuple is not used, just a single value:
--
-- >>> let u = openUnionLift (2.2 :: Double) :: OpenUnion '[Double]
-- >>> let dblHandler = (\dbl -> "got a double") :: Double -> String
-- >>> catchesOpenUnion dblHandler u :: String
-- "got a double"
catchesOpenUnion
  :: ToOpenProduct tuple (ReturnX x as)
  => tuple -> OpenUnion as -> x
catchesOpenUnion tuple u =
  runIdentity $
    catchesUnionProduct (tupleToOpenProduct tuple) u

-- | Just like 'relaxUnion' but for 'OpenUnion'.
--
-- >>> let u = openUnionLift (3.5 :: Double) :: Union Identity '[Double, String]
-- >>> relaxOpenUnion u :: Union Identity '[Char, Double, Int, String, Float]
-- Identity 3.5
relaxOpenUnion :: Contains as bs => OpenUnion as -> OpenUnion bs
relaxOpenUnion (This as) = unionLift as
relaxOpenUnion (That u) = relaxUnion u

-- | This function allows you to try to remove individual types from an
-- 'OpenUnion'.
--
-- This can be used to handle only certain types in an 'OpenUnion', instead of
-- having to handle all of them at the same time.  This can be more convenient
-- than a function like 'catchesOpenUnion'.
--
-- ==== __Examples__
--
-- Handling a type in an 'OpenUnion':
--
-- >>> let u = openUnionLift ("hello" :: String) :: OpenUnion '[String, Double]
-- >>> openUnionRemove u :: Either (OpenUnion '[Double]) String
-- Right "hello"
--
-- Failing to handle a type in an 'OpenUnion':
--
-- >>> let u = openUnionLift (3.5 :: Double) :: OpenUnion '[String, Double]
-- >>> openUnionRemove u :: Either (OpenUnion '[Double]) String
-- Left (Identity 3.5)
--
-- Note that if you have an 'OpenUnion' with multiple of the same type, they will
-- all be handled at the same time:
--
-- >>> let u = That (This (Identity 3.5)) :: OpenUnion '[String, Double, Char, Double]
-- >>> openUnionRemove u :: Either (OpenUnion '[String, Char]) Double
-- Right 3.5
openUnionRemove
  :: forall a as
   . ElemRemove a as
  => OpenUnion as
  -> Either (OpenUnion (Remove a as)) a
openUnionRemove = fmap runIdentity . unionRemove

-- | Handle a single case in an 'OpenUnion'.  This is similar to 'openUnion'
-- but lets you handle any case within the 'OpenUnion', not just the first one.
--
-- ==== __Examples__
--
-- Handling the first item in an 'OpenUnion':
--
-- >>> let u = This 3.5 :: OpenUnion '[Double, Int]
-- >>> let printDouble = print :: Double -> IO ()
-- >>> let printUnion = print :: OpenUnion '[Int] -> IO ()
-- >>> openUnionHandle printUnion printDouble u
-- 3.5
--
-- Handling a middle item in an 'OpenUnion':
--
-- >>> let u2 = openUnionLift (3.5 :: Double) :: OpenUnion '[Char, Double, Int]
-- >>> let printUnion = print :: OpenUnion '[Char, Int] -> IO ()
-- >>> openUnionHandle printUnion printDouble u2
-- 3.5
--
-- Failing to handle an item in an 'OpenUnion'.  In the following example, the
-- @printUnion@ function is called:
--
-- >>> let u2 = openUnionLift 'c' :: OpenUnion '[Char, Double, Int]
-- >>> let printUnion = print :: OpenUnion '[Char, Int] -> IO ()
-- >>> openUnionHandle printUnion printDouble u2
-- Identity 'c'
--
-- If you have duplicates in your 'OpenUnion', they will both get handled with
-- a single call to 'openUnionHandle'.
--
-- >>> let u3 = That (This 3.5) :: OpenUnion '[Double, Double, Int]
-- >>> let printUnion = print :: OpenUnion '[Int] -> IO ()
-- >>> openUnionHandle printUnion printDouble u3
-- 3.5
--
-- Use 'absurdOpenUnion' to handle an empty 'OpenUnion':
--
-- >>> let u4 = This 3.5 :: OpenUnion '[Double]
-- >>> openUnionHandle (absurdUnion :: OpenUnion '[] -> IO ()) printDouble u4
-- 3.5
openUnionHandle
  :: ElemRemove a as
  => (OpenUnion (Remove a as) -> b)
  -> (a -> b)
  -> OpenUnion as
  -> b
openUnionHandle unionHandler aHandler =
  unionHandle unionHandler (aHandler . runIdentity)

---------------
-- Instances --
---------------

instance NFData (Union f '[]) where
  rnf = absurdUnion

instance (NFData (f a), NFData (Union f as)) => NFData (Union f (a ': as)) where
  rnf = union rnf rnf

instance Show (Union f '[]) where
  showsPrec _ = absurdUnion

instance (Show (f a), Show (Union f as)) => Show (Union f (a ': as)) where
  showsPrec n = union (showsPrec n) (showsPrec n)

-- | This will always fail, since @'Union' f \'[]@ is effectively 'Void'.
instance Read (Union f '[]) where
  readsPrec :: Int -> ReadS (Union f '[])
  readsPrec _ _ = []

-- | This is only a valid instance when the 'Read' instances for the types
-- don't overlap.
--
-- For instance, imagine we are working with a 'Union' of a 'String' and a 'Double'.
-- @3.5@ can only be read as a 'Double', not as a 'String'.
-- Oppositely, @\"hello\"@ can only be read as a 'String', not as a 'Double'.
--
-- >>> let o = readMaybe "Identity 3.5" :: Maybe (Union Identity '[Double, String])
-- >>> o
-- Just (Identity 3.5)
-- >>> o >>= openUnionMatch :: Maybe Double
-- Just 3.5
-- >>> o >>= openUnionMatch :: Maybe String
-- Nothing
--
-- >>> let p = readMaybe "Identity \"hello\"" :: Maybe (Union Identity '[Double, String])
-- >>> p
-- Just (Identity "hello")
-- >>> p >>= openUnionMatch :: Maybe Double
-- Nothing
-- >>> p >>= openUnionMatch :: Maybe String
-- Just "hello"
--
-- However, imagine are we working with a 'Union' of a 'String' and
-- 'Data.Text.Text'.  @\"hello\"@ can be 'read' as both a 'String' and
-- 'Data.Text.Text'.  However, in the following example, it can only be read as
-- a 'String':
--
-- >>> let q = readMaybe "Identity \"hello\"" :: Maybe (Union Identity '[String, Text])
-- >>> q
-- Just (Identity "hello")
-- >>> q >>= openUnionMatch :: Maybe String
-- Just "hello"
-- >>> q >>= openUnionMatch :: Maybe Text
-- Nothing
--
-- If the order of the types is flipped around, we are are able to read @\"hello\"@
-- as a 'Text' but not as a 'String'.
--
-- >>> let r = readMaybe "Identity \"hello\"" :: Maybe (Union Identity '[Text, String])
-- >>> r
-- Just (Identity "hello")
-- >>> r >>= openUnionMatch :: Maybe String
-- Nothing
-- >>> r >>= openUnionMatch :: Maybe Text
-- Just "hello"
instance (Read (f a), Read (Union f as)) => Read (Union f (a ': as)) where
  readPrec :: ReadPrec (Union f (a ': as))
  readPrec = fmap This readPrec <++ fmap That readPrec

instance Eq (Union f '[]) where
  (==) = absurdUnion

instance (Eq (f a), Eq (Union f as)) => Eq (Union f (a ': as)) where
    This a1 == This a2 = a1 == a2
    That u1 == That u2 = u1 == u2
    _       == _       = False

instance Ord (Union f '[]) where
  compare = absurdUnion

instance (Ord (f a), Ord (Union f as)) => Ord (Union f (a ': as))
  where
    compare (This a1) (This a2) = compare a1 a2
    compare (That u1) (That u2) = compare u1 u2
    compare (This _)  (That _)  = LT
    compare (That _)  (This _)  = GT

instance ToJSON (Union f '[]) where
  toJSON :: Union f '[] -> Value
  toJSON = absurdUnion

instance (ToJSON (f a), ToJSON (Union f as)) => ToJSON (Union f (a ': as)) where
  toJSON :: Union f (a ': as) -> Value
  toJSON = union toJSON toJSON

-- | This will always fail, since @'Union' f \'[]@ is effectively 'Void'.
instance FromJSON (Union f '[]) where
  parseJSON :: Value -> Parser (Union f '[])
  parseJSON _ = fail "Value of Union f '[] can never be created"

-- | This is only a valid instance when the 'FromJSON' instances for the types
-- don't overlap.
--
-- This is similar to the 'Read' instance.
instance (FromJSON (f a), FromJSON (Union f as)) => FromJSON (Union f (a ': as)) where
  parseJSON :: Value -> Parser (Union f (a ': as))
  parseJSON val = fmap This (parseJSON val) <|> fmap That (parseJSON val)

-- instance f ~ Identity => Exception (Union f '[])

-- instance
--     ( f ~ Identity
--     , Exception a
--     , Typeable as
--     , Exception (Union f as)
--     ) => Exception (Union f (a ': as))
--   where
--     toException = union toException (toException . runIdentity)
--     fromException sE = matchR <|> matchL
--       where
--         matchR = This . Identity <$> fromException sE
--         matchL = That <$> fromException sE
