{-# LANGUAGE ScopedTypeVariables, FlexibleInstances, MultiParamTypeClasses, DeriveDataTypeable #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Interval
-- Copyright   :  (c) Masahiro Sakai 2011
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  provisional
-- Portability :  non-portable (ScopedTypeVariables, FlexibleInstances, MultiParamTypeClasses, DeriveDataTypeable)
--
-- Interval datatype.
-- 
-----------------------------------------------------------------------------
module Data.Interval
  ( EndPoint
  , Interval
  , lowerBound
  , upperBound
  , interval
  , closedInterval
  , univ
  , empty
  , singleton
  , intersection
  , null
  , member
  , pickup
  , tightenToInteger
  ) where

import Control.Monad
import Data.Maybe
import Data.Linear
import Data.Typeable
import Util (combineMaybe, isInteger)
import Prelude hiding (null)

-- | Endpoint
-- (isInclusive, value)
type EndPoint r = Maybe (Bool, r)

-- | interval
data Interval r
  = Interval
  { lowerBound :: EndPoint r -- ^ lower bound of the interval
  , upperBound :: EndPoint r -- ^ upper bound of the interval
  }
  deriving (Eq, Ord, Typeable)

instance Show r => Show (Interval r) where
  showsPrec p x  = showParen (p > appPrec) $
    showString "interval " .
    showsPrec appPrec1 (lowerBound x) .
    showChar ' ' . 
    showsPrec appPrec1 (upperBound x)

-- | smart constructor for 'Interval'
interval :: Real r => EndPoint r -> EndPoint r -> Interval r
interval lb@(Just (in1,x1)) ub@(Just (in2,x2)) =
  case x1 `compare` x2 of
    GT -> empty
    LT -> Interval lb ub
    EQ -> if in1 && in2 then Interval lb ub else empty
interval lb ub = Interval lb ub

closedInterval :: Real r => r -> r -> Interval r
closedInterval lb ub = interval (Just (True, lb)) (Just (True, ub))

-- | (-∞, ∞)
univ :: Interval r
univ = Interval Nothing Nothing

-- | empty (contradicting) interval
empty :: Num r => Interval r
empty = Interval (Just (False,0)) (Just (False,0))

-- | singleton set \[x,x\]
singleton :: r -> Interval r
singleton x = Interval (Just (True, x)) (Just (True, x))

-- | intersection of two intervals
intersection :: forall r. Real r => Interval r -> Interval r -> Interval r
intersection (Interval l1 u1) (Interval l2 u2) = interval (maxEP l1 l2) (minEP u1 u2)
  where 
    maxEP :: EndPoint r -> EndPoint r -> EndPoint r
    maxEP = combineMaybe $ \(in1,x1) (in2,x2) ->
      ( case x1 `compare` x2 of
          EQ -> in1 && in2
          LT -> in2
          GT -> in1
      , max x1 x2
      )

    minEP :: EndPoint r -> EndPoint r -> EndPoint r
    minEP = combineMaybe $ \(in1,x1) (in2,x2) ->
      ( case x1 `compare` x2 of
          EQ -> in1 && in2
          LT -> in1
          GT -> in2
      , min x1 x2
      )

-- | Is the interval empty?
null :: (Real r, Fractional r) => Interval r -> Bool
null i = not $ isJust (pickup i)

-- | Is the element in the interval?
member :: Real r => r -> Interval r -> Bool
member x (Interval lb ub) = testLB x lb && testUB x ub
  where
    testLB x Nothing = True
    testLB x (Just (in1,x1)) = if in1 then x1 <= x else x1 < x
    testUB x Nothing = True
    testUB x (Just (in2,x2)) = if in2 then x <= x2 else x < x2

-- | pick up an element from the interval if the interval is not empty.
pickup :: (Real r, Fractional r) => Interval r -> Maybe r
pickup (Interval Nothing Nothing) = Just 0
pickup (Interval (Just (in1,x1)) Nothing) = Just $ if in1 then x1 else x1+1
pickup (Interval Nothing (Just (in2,x2))) = Just $ if in2 then x2 else x2-1
pickup (Interval (Just (in1,x1)) (Just (in2,x2))) =
  case x1 `compare` x2 of
    GT -> Nothing
    LT -> Just $ (x1+x2) / 2
    EQ -> if in1 && in2 then Just x1 else Nothing

-- | tightening intervals by ceiling lower bounds and flooring upper bounds.
tightenToInteger :: forall r. (RealFrac r) => Interval r -> Interval r
tightenToInteger (Interval lb ub) = interval (fmap tightenLB lb) (fmap tightenUB ub)
  where
    tightenLB (incl,lb) =
      ( True
      , if isInteger lb && not incl
        then lb + 1
        else fromIntegral (ceiling lb :: Integer)
      )
    tightenUB (incl,ub) =
      ( True
      , if isInteger ub && not incl
        then ub - 1
        else fromIntegral (floor ub :: Integer)
      )

-- | Interval airthmetics.
-- Note that this instance does not satisfy algebraic laws of linear spaces.
instance Real r => Module r (Interval r) where
  lzero = singleton 0
  Interval lb1 ub1 .+. Interval lb2 ub2 = interval (f lb1 lb2) (f ub1 ub2)
    where
      f = liftM2 $ \(in1,x1) (in2,x2) -> (in1 && in2, x1 + x2)
  c .*. Interval lb ub
    | c < 0     = interval (f ub) (f lb)
    | otherwise = interval (f lb) (f ub)
    where
      f Nothing = Nothing
      f (Just (incl,val)) = Just (incl, c * val)

instance (Real r, Fractional r) => Linear r (Interval r)

appPrec, appPrec1 :: Int
appPrec = 10
appPrec1 = appPrec + 1
