{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  FourierMotzkin
-- Copyright   :  (c) Masahiro Sakai 2011
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Naïve implementation of Fourier-Motzkin Variable Elimination
-- 
-- see http://users.cecs.anu.edu.au/~michaeln/pubs/arithmetic-dps.pdf for detail
--
-----------------------------------------------------------------------------
module FourierMotzkin
    ( module Expr
    , module Formula
    , Tm (..)
    , Lit (..)
    , DNF (..)
    , eliminateQuantifiersR
    , eliminateQuantifiersZ
    , solveR
    , solveZ
    , termR -- FIXME
    ) where

import Control.Monad
import Data.List
import Data.Maybe
import Data.Ratio
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS

import Expr
import Formula
import Tm

-- ---------------------------------------------------------------------------

type TmZ = Tm Integer

-- | (t,c) represents t/c, and c must be >0.
type Rat = (TmZ, Integer)

evalRat :: Model Rational -> Rat -> Rational
evalRat model (Tm t, c1) = sum [(model' IM.! var) * (c % c1) | (var,c) <- IM.toList t]
  where model' = IM.insert (-1) 1 model

-- | Literal
data Lit = Nonneg TmZ | Pos TmZ deriving (Show, Eq, Ord)

instance Variables Lit where
  vars (Pos t) = vars t
  vars (Nonneg t) = vars t

-- | Disjunctive normal form
newtype DNF = DNF{ unDNF :: [[Lit]] } deriving (Show)

instance Boolean DNF where
  true = DNF [[]]
  false = DNF []
  notF (DNF xs) = DNF . sequence . map (map f) $ xs
    where
      f :: Lit -> Lit
      f (Pos t) = Nonneg (negateTm t)
      f (Nonneg t) = Pos (negateTm t)
  DNF xs .&&. DNF ys = DNF [x++y | x<-xs, y<-ys]
  DNF xs .||. DNF ys = DNF (xs++ys)

-- 制約集合の単純化
-- It returns Nothing when a inconsistency is detected.
simplify :: [Lit] -> Maybe [Lit]
simplify = fmap concat . mapM f
  where
    f :: Lit -> Maybe [Lit]
    f lit@(Pos tm) =
      case g tm of
        Just x -> guard (x > 0) >> return []
        Nothing -> return [lit]
    f lit@(Nonneg tm) =
      case g tm of
        Just x -> guard (x >= 0) >> return []
        Nothing -> return [lit]

    g :: TmZ -> Maybe Integer
    g (Tm tm) =
      case IM.toList tm of
        [] -> Just 0
        [(-1,x)] -> Just x
        _ -> Nothing

-- ---------------------------------------------------------------------------

atomR :: RelOp -> Expr Rational -> Expr Rational -> Maybe DNF
atomR op a b = do
  a' <- termR a
  b' <- termR b
  return $ case op of
    Le -> DNF [[a' `leR` b']]
    Lt -> DNF [[a' `ltR` b']]
    Ge -> DNF [[a' `geR` b']]
    Gt -> DNF [[a' `gtR` b']]
    Eql -> DNF [[a' `leR` b', a' `geR` b']]
    NEq -> DNF [[a' `ltR` b'], [a' `gtR` b']]

termR :: Expr Rational -> Maybe Rat
termR (Const c) = return (constTm (numerator c), denominator c)
termR (Var v) = return (varTm v, 1)
termR (a :+: b) = do
  (t1,c1) <- termR a
  (t2,c2) <- termR b
  return (scaleTm c2 t1 .+. scaleTm c1 t2, c1*c2)
termR (a :*: b) = do
  (t1,c1) <- termR a
  (t2,c2) <- termR b
  msum [ do{ c <- asConst t1; return (scaleTm c t2, c1*c2) }
       , do{ c <- asConst t2; return (scaleTm c t1, c1*c2) }
       ]
termR (a :/: b) = do
  (t1,c1) <- termR a
  (t2,c2) <- termR b
  c3 <- asConst t2
  guard $ c3 /= 0
  return (scaleTm c2 t1, c1*c3)

leR, ltR, geR, gtR :: Rat -> Rat -> Lit
leR (tm1,c) (tm2,d) = Nonneg $ normalizeTmR $ scaleTm c tm2 .-. scaleTm d tm1
ltR (tm1,c) (tm2,d) = Pos $ normalizeTmR $ scaleTm c tm2 .-. scaleTm d tm1
geR = flip leR
gtR = flip gtR

normalizeTmR :: TmZ -> TmZ
normalizeTmR (Tm m) = Tm (IM.map (`div` d) m)
  where d = gcd' $ map snd $ IM.toList m

-- ---------------------------------------------------------------------------

atomZ :: RelOp -> Expr Rational -> Expr Rational -> Maybe DNF
atomZ op a b = do
  (tm1,c1) <- termR a
  (tm2,c2) <- termR b
  let a' = scaleTm c2 tm1
      b' = scaleTm c1 tm2
  return $ case op of
    Le -> DNF [[a' `leZ` b']]
    Lt -> DNF [[a' `ltZ` b']]
    Ge -> DNF [[a' `geZ` b']]
    Gt -> DNF [[a' `gtZ` b']]
    Eql -> eqZ a' b'
    NEq -> DNF [[a' `ltZ` b'], [a' `gtZ` b']]

leZ, ltZ, geZ, gtZ :: TmZ -> TmZ -> Lit
-- Note that constants may be floored by division
leZ tm1 tm2 = Nonneg (Tm (IM.map (`div` d) m))
  where
    Tm m = tm2 .-. tm1
    d = gcd' [c | (var,c) <- IM.toList m, var /= -1]
ltZ tm1 tm2 = (tm1 .+. constTm 1) `leZ` tm2
geZ = flip leZ
gtZ = flip gtZ

eqZ :: TmZ -> TmZ -> DNF
eqZ tm1 tm2
  = if fromMaybe 0 (IM.lookup (-1) m) `mod` d == 0
    then DNF [[Nonneg tm, Nonneg (negateTm tm)]]
    else false
  where
    Tm m = tm1 .-. tm2
    tm = Tm (IM.map (`div` d) m)
    d = gcd' [c | (var,c) <- IM.toList m, var /= -1]

-- ---------------------------------------------------------------------------

{-
(ls1,ls2,us1,us2) represents
{ x | ∀(M,c)∈ls1. M/c≤x, ∀(M,c)∈ls2. M/c<x, ∀(M,c)∈us1. x≤M/c, ∀(M,c)∈us2. x<M/c }
-}
type BoundsR = ([Rat], [Rat], [Rat], [Rat])

eliminateR :: Var -> [Lit] -> DNF
eliminateR v xs = DNF [rest] .&&. boundConditionsR bnd
  where
    (bnd, rest) = collectBoundsR v xs

collectBoundsR :: Var -> [Lit] -> (BoundsR, [Lit])
collectBoundsR v = foldr phi (([],[],[],[]),[])
  where
    phi :: Lit -> (BoundsR, [Lit]) -> (BoundsR, [Lit])
    phi lit@(Nonneg t) x = f False lit t x
    phi lit@(Pos t) x = f True lit t x

    f :: Bool -> Lit -> TmZ -> (BoundsR, [Lit]) -> (BoundsR, [Lit])
    f strict lit (Tm t) (bnd@(ls1,ls2,us1,us2), xs) = 
      case c `compare` 0 of
        EQ -> (bnd, lit : xs)
        GT ->
          if strict
          then ((ls1, (negateTm t', c) : ls2, us1, us2), xs) -- 0 < cx + M ⇔ -M/c <  x
          else (((negateTm t', c) : ls1, ls2, us1, us2), xs) -- 0 ≤ cx + M ⇔ -M/c ≤ x
        LT -> 
          if strict
          then ((ls1, ls2, us1, (t', negate c) : us2), xs) -- 0 < cx + M ⇔ x < M/-c
          else ((ls1, ls2, (t', negate c) : us1, us2), xs) -- 0 ≤ cx + M ⇔ x ≤ M/-c
      where
        c = fromMaybe 0 $ IM.lookup v t
        t' = Tm $ IM.delete v t

boundConditionsR :: BoundsR -> DNF
boundConditionsR  (ls1, ls2, us1, us2) = DNF $ maybeToList $ simplify $ 
  [ x `leR` y | x <- ls1, y <- us1 ] ++
  [ x `ltR` y | x <- ls1, y <- us2 ] ++ 
  [ x `ltR` y | x <- ls2, y <- us1 ] ++
  [ x `ltR` y | x <- ls2, y <- us2 ]

eliminateQuantifiersR :: Formula Rational -> Maybe DNF
eliminateQuantifiersR = f
  where
    f T = return true
    f F = return false
    f (Atom (Rel a op b)) = atomR op a b
    f (And a b) = liftM2 (.&&.) (f a) (f b)
    f (Or a b) = liftM2 (.||.) (f a) (f b)
    f (Not a) = f (pushNot a)
    f (Imply a b) = f (Or (Not a) b)
    f (Equiv a b) = f (And (Imply a b) (Imply b a))
    f (Forall v a) = do
      dnf <- f (Exists v (pushNot a))
      return (notF dnf)
    f (Exists v a) = do
      dnf <- f a
      return $ orF [eliminateR v xs | xs <- unDNF dnf]

solveR :: Formula Rational -> SatResult Rational
solveR formula =
  case eliminateQuantifiersR formula of
    Nothing -> Unknown
    Just dnf ->
      case msum [solveR' vs xs | xs <- unDNF dnf] of
        Nothing -> Unsat
        Just m -> Sat m
  where
    vs = IS.toList (vars formula)

solveR' :: [Var] -> [Lit] -> Maybe (Model Rational)
solveR' vs xs = simplify xs >>= go vs
  where
    go [] [] = return IM.empty
    go [] _ = mzero
    go (v:vs) ys = msum (map f (unDNF (boundConditionsR bnd)))
      where
        (bnd, rest) = collectBoundsR v ys
        f zs = do
          model <- go vs (zs ++ rest)
          val <- pickupR (evalBoundsR model bnd)
          return $ IM.insert v val model

evalBoundsR :: Model Rational -> BoundsR -> IntervalR
evalBoundsR model (ls1,ls2,us1,us2) =
  foldl' intersectR univR $ 
    [ (Just (True, evalRat model x), Nothing)  | x <- ls1 ] ++
    [ (Just (False, evalRat model x), Nothing) | x <- ls2 ] ++
    [ (Nothing, Just (True, evalRat model x))  | x <- us1 ] ++
    [ (Nothing, Just (False, evalRat model x)) | x <- us2 ]

-- ---------------------------------------------------------------------------

-- | Endpoint
-- (isInclusive, value)
type EP = Maybe (Bool, Rational)

type IntervalR = (EP, EP)

univR :: IntervalR
univR = (Nothing, Nothing)

intersectR :: IntervalR -> IntervalR -> IntervalR
intersectR (l1,u1) (l2,u2) = (maxEP l1 l2, minEP u1 u2)
  where 
    maxEP :: EP -> EP -> EP
    maxEP = combine $ \(in1,x1) (in2,x2) ->
      ( case x1 `compare` x2 of
          EQ -> in1 && in2
          LT -> in2
          GT -> in1
      , max x1 x2
      )

    minEP :: EP -> EP -> EP
    minEP = combine $ \(in1,x1) (in2,x2) ->
      ( case x1 `compare` x2 of
          EQ -> in1 && in2
          LT -> in1
          GT -> in2
      , min x1 x2
      )

pickupR :: IntervalR -> Maybe Rational
pickupR (Nothing,Nothing) = Just 0
pickupR (Just (in1,x1), Nothing) = Just $ if in1 then x1 else x1+1
pickupR (Nothing, Just (in2,x2)) = Just $ if in2 then x2 else x2-1
pickupR (Just (in1,x1), Just (in2,x2)) =
  case x1 `compare` x2 of
    GT -> Nothing
    LT -> Just $ (x1+x2) / 2
    EQ -> if in1 && in2 then Just x1 else Nothing

-- ---------------------------------------------------------------------------

{-
(ls,us) represents
{ x | ∀(M,c)∈ls. M/c≤x, ∀(M,c)∈us. x≤M/c }
-}
type BoundsZ = ([Rat],[Rat])

eliminateZ :: Var -> [Lit] -> DNF
eliminateZ v xs = DNF [rest] .&&. boundConditionsZ bnd
   where
     (bnd,rest) = collectBoundsZ v xs

collectBoundsZ :: Var -> [Lit] -> (BoundsZ,[Lit])
collectBoundsZ v = foldr phi (([],[]),[])
  where
    phi :: Lit -> (BoundsZ,[Lit]) -> (BoundsZ,[Lit])
    phi (Pos t) x = phi (Nonneg (t .-. constTm 1)) x
    phi lit@(Nonneg (Tm t)) ((ls,us),xs) =
      case c `compare` 0 of
        EQ -> ((ls, us), lit : xs)
        GT -> (((negateTm t', c) : ls, us), xs) -- 0 ≤ cx + M ⇔ -M/c ≤ x
        LT -> ((ls, (t', negate c) : us), xs)   -- 0 ≤ cx + M ⇔ x ≤ M/-c
      where
        c = fromMaybe 0 $ IM.lookup v t
        t' = Tm $ IM.delete v t

boundConditionsZ :: BoundsZ -> DNF
boundConditionsZ (ls,us) = DNF $ catMaybes $ map simplify $ cond1 : cond2
  where
     cond1 =
       [ constTm ((a-1)*(b-1)) `leZ` (scaleTm a d .-. scaleTm b c)
       | (c,a)<-ls , (d,b)<-us ]
     cond2 = 
       [ [scaleTm a' c `leZ` scaleTm a val | (c,a)<-ls] ++
         [scaleTm b val `geZ` scaleTm a' d | (d,b)<-us]
       | not (null us)
       , let m = maximum [b | (_,b)<-us]
       ,  (c',a') <- ls
       , k <- [0 .. (m*a'-a'-m) `div` m]
       , let val = c' .+. constTm k
       -- x = val / a'
       -- c / a ≤ x ⇔ c / a ≤ val / a' ⇔ a' c ≤ a val
       -- x ≤ d / b ⇔ val / a' ≤ d / b ⇔ b val ≤ a' d
       ]

eliminateQuantifiersZ :: Formula Rational -> Maybe DNF
eliminateQuantifiersZ = f
  where
    f T = return true
    f F = return false
    f (Atom (Rel a op b)) = atomZ op a b
    f (And a b) = liftM2 (.&&.) (f a) (f b)
    f (Or a b) = liftM2 (.||.) (f a) (f b)
    f (Not a) = f (pushNot a)
    f (Imply a b) = f (Or (Not a) b)
    f (Equiv a b) = f (And (Imply a b) (Imply b a))
    f (Forall v a) = do
      dnf <- f (Exists v (pushNot a))
      return $ notF dnf
    f (Exists v a) = do
      dnf <- f a
      return $ orF [eliminateZ v xs | xs <- unDNF dnf]

solveZ :: Formula Rational -> SatResult Integer
solveZ formula =
  case eliminateQuantifiersZ formula of
    Nothing -> Unknown
    Just dnf ->
      case msum [solveZ' vs xs | xs <- unDNF dnf] of
        Nothing -> Unsat
        Just m -> Sat m
  where
    vs = IS.toList (vars formula)

solveZ' :: [Var] -> [Lit] -> Maybe (Model Integer)
solveZ' vs xs = simplify xs >>= go vs
  where
    go :: [Var] -> [Lit] -> Maybe (Model Integer)
    go [] [] = return IM.empty
    go [] _ = mzero
    go (v:vs) ys = msum (map f (unDNF (boundConditionsZ bnd)))
      where
        (bnd, rest) = collectBoundsZ v ys
        f zs = do
          model <- go vs (zs ++ rest)
          val <- pickupZ (evalBoundsZ model bnd)
          return $ IM.insert v val model

evalBoundsZ :: Model Integer -> BoundsZ -> IntervalZ
evalBoundsZ model (ls,us) =
  foldl' intersectZ univZ $ 
    [ (Just (ceiling (evalTm model x % c)), Nothing) | (x,c) <- ls ] ++ 
    [ (Nothing, Just (floor (evalTm model x % c))) | (x,c) <- us ]

-- ---------------------------------------------------------------------------

type IntervalZ = (Maybe Integer, Maybe Integer)

univZ :: IntervalZ
univZ = (Nothing, Nothing)

intersectZ :: IntervalZ -> IntervalZ -> IntervalZ
intersectZ (l1,u1) (l2,u2) = (combine max l1 l2, combine min u1 u2)

pickupZ :: IntervalZ -> Maybe Integer
pickupZ (Nothing,Nothing) = return 0
pickupZ (Just x, Nothing) = return x
pickupZ (Nothing, Just x) = return x
pickupZ (Just x, Just y) = if x <= y then return x else mzero 

-- ---------------------------------------------------------------------------

gcd' :: [Integer] -> Integer
gcd' [] = 1
gcd' xs = foldl1' gcd xs

combine :: (a -> a -> a) -> Maybe a -> Maybe a -> Maybe a
combine _ Nothing y = y
combine _ x Nothing = x
combine f (Just x) (Just y) = Just (f x y)

-- ---------------------------------------------------------------------------

{-
7x + 12y + 31z = 17
3x + 5y + 14z = 7
1 ≤ x ≤ 40
-50 ≤ y ≤ 50

satisfiable in R
but unsatisfiable in Z
-}
test1 :: Formula Rational
test1 = c1 .&&. c2 .&&. c3 .&&. c4
  where
    x = Var 0
    y = Var 1
    z = Var 2
    c1 = 7*x + 12*y + 31*z .==. 17
    c2 = 3*x + 5*y + 14*z .==. 7
    c3 = 1 .<=. x .&&. x .<=. 40
    c4 = (-50) .<=. y .&&. y .<=. 50

{-
27 ≤ 11x+13y ≤ 45
-10 ≤ 7x-9y ≤ 4

satisfiable in R
but unsatisfiable in Z
-}
test2 :: Formula Rational
test2 = c1 .&&. c2
  where
    x = Var 0
    y = Var 1
    t1 = 11*x + 13*y
    t2 = 7*x - 9*y
    c1 = 27 .<=. t1 .&&. t1 .<=. 45
    c2 = (-10) .<=. t2 .&&. t2 .<=. 4

-- ---------------------------------------------------------------------------
