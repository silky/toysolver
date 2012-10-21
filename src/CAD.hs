{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables, BangPatterns #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  CAD
-- Copyright   :  (c) Masahiro Sakai 2012
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  provisional
-- Portability :  non-portable (ScopedTypeVariables)
--
-- References:
--
-- *  Christian Michaux and Adem Ozturk.
--    Quantifier Elimination following Muchnik
--    <https://math.umons.ac.be/preprints/src/Ozturk020411.pdf>
--
-- *  Arnab Bhattacharyya.
--    Something you should know about: Quantifier Elimination (Part I)
--    <http://cstheory.blogoverflow.com/2011/11/something-you-should-know-about-quantifier-elimination-part-i/>
-- 
-- *  Arnab Bhattacharyya.
--    Something you should know about: Quantifier Elimination (Part II)
--    <http://cstheory.blogoverflow.com/2012/02/something-you-should-know-about-quantifier-elimination-part-ii/>
--
-----------------------------------------------------------------------------
module CAD where

import Control.Exception
import Control.Monad.State
import Data.List
import Data.Maybe
import Data.Ord
import qualified Data.Map as Map
import qualified Data.Set as Set
import Text.Printf

import Data.ArithRel
import qualified Data.AlgebraicNumber as AReal
import Data.Formula (DNF (..))
import Data.Polynomial

import Debug.Trace

-- ---------------------------------------------------------------------------

data Point c = NegInf | RootOf (UPolynomial c) Int | PosInf
  deriving (Eq, Ord, Show)

data Cell c
  = Point (Point c)
  | Interval (Point c) (Point c)
  deriving (Eq, Ord, Show)

type Model v = Map.Map v AReal.AReal

-- ---------------------------------------------------------------------------

data Sign = Neg | Zero | Pos
  deriving (Eq, Ord, Show)

signNegate :: Sign -> Sign
signNegate Neg  = Pos
signNegate Zero = Zero
signNegate Pos  = Neg

signMul :: Sign -> Sign -> Sign
signMul Pos s  = s
signMul s Pos  = s
signMul Neg s  = signNegate s
signMul s Neg  = signNegate s
signMul _ _    = Zero

signDiv :: Sign -> Sign -> Sign
signDiv s Pos  = s
signDiv _ Zero = error "signDiv: division by zero"
signDiv s Neg  = signNegate s

signExp :: Sign -> Integer -> Sign
signExp _ 0    = Pos
signExp Pos _  = Pos
signExp Zero _ = Zero
signExp Neg n  = if even n then Pos else Neg

signOfConst :: (Num a, Ord a) => a -> Sign
signOfConst r =
  case r `compare` 0 of
    LT -> Neg
    EQ -> Zero
    GT -> Pos

-- ---------------------------------------------------------------------------

type SignConf c = [(Cell c, Map.Map (UPolynomial c) Sign)]

emptySignConf :: SignConf c
emptySignConf =
  [ (Point NegInf, Map.empty)
  , (Interval NegInf PosInf, Map.empty)
  , (Point PosInf, Map.empty)
  ]

showSignConf :: forall c. (Num c, Ord c, RenderCoeff c) => SignConf c -> [String]
showSignConf = f
  where
    f :: SignConf c -> [String]
    f = concatMap $ \(cell, m) -> showCell cell : g m

    g :: Map.Map (UPolynomial c) Sign -> [String]
    g m =
      [printf "  %s: %s" (render p) (showSign s) | (p, s) <- Map.toList m]

    showCell :: Cell c -> String
    showCell (Point pt) = showPoint pt
    showCell (Interval lb ub) = printf "(%s, %s)" (showPoint lb) (showPoint ub)

    showPoint :: Point c -> String
    showPoint NegInf = "-inf" 
    showPoint PosInf = "+inf"
    showPoint (RootOf p n) = "rootOf(" ++ render p ++ ", " ++ show n ++ ")"

    showSign :: Sign -> String
    showSign Pos  = "+"
    showSign Neg  = "-"
    showSign Zero = "0"

-- ---------------------------------------------------------------------------

-- modified reminder
mr
  :: forall k. (Ord k, Show k, Num k, RenderCoeff k)
  => UPolynomial k
  -> UPolynomial k
  -> (k, Integer, UPolynomial k)
mr p q
  | n >= m    = assert (constant (bm^(n-m+1)) * p == q * l + r && m > deg r) $ (bm, n-m+1, r)
  | otherwise = error "mr p q: not (deg p >= deg q)"
  where
    x = var ()
    n = deg p
    m = deg q
    (bm, _) = leadingTerm grlex q
    (l,r) = f p n

    f :: UPolynomial k -> Integer -> (UPolynomial k, UPolynomial k)
    f p n
      | n==m =
          let l = constant an
              r = constant bm * p - constant an * q
          in assert (constant (bm^(n-m+1)) * p == q*l + r && m > deg r) $ (l, r)
      | otherwise =
          let p'     = (constant bm * p - constant an * x^(n-m) * q)
              (l',r) = f p' (n-1)
              l      = l' + constant (an*bm^(n-m)) * x^(n-m)
          in assert (n > deg p') $
             assert (constant (bm^(n-m+1)) * p == q*l + r && m > deg r) $ (l, r)
      where
        an = coeff (mmFromList [((), n)]) p

test_mr_1 :: (Coeff Int, Integer, UPolynomial (Coeff Int))
test_mr_1 = mr (asPolynomialOf p 3) (asPolynomialOf q 3)
  where
    a = var 0
    b = var 1
    c = var 2
    x = var 3
    p = a*x^(2::Int) + b*x + c
    q = 2*a*x + b

test_mr_2 :: (Coeff Int, Integer, UPolynomial (Coeff Int))
test_mr_2 = mr (asPolynomialOf p 3) (asPolynomialOf p 3)
  where
    a = var 0
    b = var 1
    c = var 2
    x = var 3
    p = a*x^(2::Int) + b*x + c

asPolynomialOf :: (Eq k, Ord k, Num k, Ord v, Show v) => Polynomial k v -> v -> UPolynomial (Polynomial k v)
asPolynomialOf p v = fromTerms $ do
  (c,mm) <- terms p
  let m = mmToMap mm
  return ( fromTerms [(c, mmFromMap (Map.delete v m))]
         , mmFromList [((), Map.findWithDefault 0 v m)]
         )

-- ---------------------------------------------------------------------------

solveU :: [(UPolynomial Rational, Sign)] -> Maybe AReal.AReal
solveU cs = listToMaybe $ do
  (cell, m) <- buildSignConfU (map fst cs)
  guard $ and [checkSign m p s | (p,s) <- cs]
  findSample cell

  where
    checkSign m p s =
      if 1 > deg p 
        then signOfConst (coeff mmOne p) == s
        else (m Map.! p) == s

    findSample :: MonadPlus m => Cell Rational -> m AReal.AReal
    findSample (Point (RootOf p n)) =
      return $ AReal.realRoots p !! n
    findSample (Interval NegInf (RootOf p n)) =
      return $ fromInteger $ AReal.floor'   ((AReal.realRoots p !! n) - 1)
    findSample (Interval (RootOf p n) PosInf) =
      return $ fromInteger $ AReal.ceiling' ((AReal.realRoots p !! n) + 1)
    findSample (Interval (RootOf p1 n1) (RootOf p2 n2)) = assert (pt1 < pt2) $ return $ (pt1 + pt2) / 2
      where
        pt1 = AReal.realRoots p1 !! n1
        pt2 = AReal.realRoots p2 !! n2
    findSample _ = mzero

buildSignConfU :: [UPolynomial Rational] -> SignConf Rational
buildSignConfU ps = foldl' (flip refineSignConfU) emptySignConf ts
  where
    ps2 = collectPolynomialsU (Set.fromList ps)
    ts = sortBy (comparing deg) (Set.toList ps2)

collectPolynomialsU :: (Fractional r, Ord r) => Set.Set (UPolynomial r) -> Set.Set (UPolynomial r)
collectPolynomialsU ps = go ps1 ps1
  where
    ps1 = f ps

    f :: Set.Set (UPolynomial r) -> Set.Set (UPolynomial r)
    f = Set.filter (\p -> deg p > 0)

    go qs ps | Set.null qs = ps
    go qs ps = go qs' ps'
      where
       rs = f $ Set.unions $
             [ Set.fromList [deriv p () | p <- Set.toList qs]
             , Set.fromList [p1 `polyMod` p2 | p1 <- Set.toList qs, p2 <- Set.toList ps, deg p1 >= deg p2, p2 /= 0]
             , Set.fromList [p1 `polyMod` p2 | p1 <- Set.toList ps, p2 <- Set.toList qs, deg p1 >= deg p2, p2 /= 0]
             ]
       qs' = rs `Set.difference` ps
       ps' = ps `Set.union` qs'

refineSignConfU :: UPolynomial Rational -> SignConf Rational -> SignConf Rational
refineSignConfU p conf = extendIntervals 0 $ map extendPoint conf
  where 
    extendPoint
      :: (Cell Rational, Map.Map (UPolynomial Rational) Sign)
      -> (Cell Rational, Map.Map (UPolynomial Rational) Sign)
    extendPoint (Point pt, m) = (Point pt, Map.insert p (signAt pt m) m)
    extendPoint x = x
 
    extendIntervals
      :: Int
      -> [(Cell Rational, Map.Map (UPolynomial Rational) Sign)]
      -> [(Cell Rational, Map.Map (UPolynomial Rational) Sign)]
    extendIntervals !n (pt1@(Point _, m1) : ((Interval lb ub), m) : pt2@(Point _, m2) : xs) =
      pt1 : ys ++ extendIntervals n2 (pt2 : xs)
      where
        s1 = m1 Map.! p
        s2 = m2 Map.! p
        n1 = if s1 == Zero then n+1 else n
        root = RootOf p n1
        (ys, n2)
           | s1 == s2   = ( [ (Interval lb ub, Map.insert p s1 m) ], n1 )
           | s1 == Zero = ( [ (Interval lb ub, Map.insert p s2 m) ], n1 )
           | s2 == Zero = ( [ (Interval lb ub, Map.insert p s1 m) ], n1 )
           | otherwise  = ( [ (Interval lb root, Map.insert p s1   m)
                            , (Point root,       Map.insert p Zero m)
                            , (Interval root ub, Map.insert p s2   m)
                            ]
                          , n1 + 1
                          )
    extendIntervals _ xs = xs
 
    signAt :: Point Rational -> Map.Map (UPolynomial Rational) Sign -> Sign
    signAt PosInf _ = signCoeff c
      where
        (c,_) = leadingTerm grlex p
    signAt NegInf _ =
      if even (deg p)
        then signCoeff c
        else signNegate (signCoeff c)
      where
        (c,_) = leadingTerm grlex p
    signAt (RootOf q _) m
      | deg r > 0 = m Map.! r
      | otherwise = signCoeff $ coeff mmOne r
      where
        r = p `polyMod` q

    signCoeff :: Rational -> Sign
    signCoeff = signOfConst

-- ---------------------------------------------------------------------------

test1a :: IO ()
test1a = mapM_ putStrLn $ showSignConf conf
  where
    x = var ()
    conf = buildSignConfU [x + 1, -2*x + 3, x]

test1b :: Bool
test1b = isJust $ solveU cs
  where
    x = var ()
    cs = [(x + 1, Pos), (-2*x + 3, Pos), (x, Pos)]

test1c :: Bool
test1c = isJust $ do
  v <- solveU cs
  guard $ and $ do
    (p, s) <- cs
    let val = eval (\_ -> v) (mapCoeff fromRational p)
    case s of
      Pos  -> return $ val > 0
      Neg  -> return $ val < 0
      Zero -> return $ val == 0
  where
    x = var ()
    cs = [(x + 1, Pos), (-2*x + 3, Pos), (x, Pos)]

test2a :: IO ()
test2a = mapM_ putStrLn $ showSignConf conf
  where
    x = var ()
    conf = buildSignConfU [x^(2::Int)]

test2b :: Bool
test2b = isNothing $ solveU cs
  where
    x = var ()
    cs = [(x^(2::Int), Neg)]

test = and [test1b, test1c, test2b]

-- ---------------------------------------------------------------------------

type Coeff v = Polynomial Rational v

type M v = StateT (Map.Map (Coeff v) [Sign]) []

runM :: M v a -> [(a, Map.Map (Coeff v) [Sign])]
runM m = runStateT m Map.empty

assume :: (Ord v, Show v, RenderVar v) => Coeff v -> [Sign] -> M v ()
assume p ss =
  if deg p == 0
    then do
      let c = coeff mmOne p
      guard $ signOfConst c `elem` ss
    else do
      m <- get
      let ss1 = Map.findWithDefault [Neg, Zero, Pos] p m
          ss2 = intersect ss1 ss
      guard $ not $ null ss2
      put $ Map.insert p ss2 m

project
  :: forall v. (Ord v, Show v, RenderVar v)
  => [(UPolynomial (Coeff v), Sign)]
  -> (DNF (Coeff v, Sign), Model v -> AReal.AReal)
project cs = (dnf, lifter)
  where
    dnf :: DNF (Coeff v, Sign)
    dnf = DNF [guess2cond gs | (_, gs) <- result]

    result :: [(Cell (Coeff v), Map.Map (Coeff v) [Sign])]
    result = runM $ do
      forM_ cs $ \(p,s) -> do
        when (1 > deg p) $ assume (coeff mmOne p) [s]
      conf <- buildSignConf (map fst cs)
      let satCells = [cell | (cell, m) <- conf, cell /= Point NegInf, cell /= Point PosInf, ok m]
      case listToMaybe satCells of
        Nothing -> mzero
        Just cell -> return cell

    ok :: Map.Map (UPolynomial (Coeff v)) Sign -> Bool
    ok m = and [checkSign m p s | (p,s) <- cs]
      where
        checkSign m p s =
          if 1 > deg p 
            then True -- already assumed
            else m Map.! p == s

    guess2cond :: Map.Map (Coeff v) [Sign] -> [(Coeff v, Sign)]
    guess2cond gs = do
      (p,ss) <- Map.toList gs
      case ss of
        [s] -> return (p,s)
        _ -> error "FIXME" -- FIXME: 後で直す

    lifter :: Model v -> AReal.AReal
    lifter model =
      case vs of
        []  -> error "project: should not happen"
        v:_ -> v
      where
        vs = do
          (cell, gs) <- result
          forM_ (Map.toList gs) $ \(cp,ss) -> do
            let val = eval (model Map.!) (mapCoeff fromRational cp)
            guard $ signOfConst val `elem` ss
          return $ findSample $ evalCell model cell

    findSample :: Cell Rational -> AReal.AReal
    findSample (Point (RootOf p n)) =
      AReal.realRoots p !! n
    findSample (Interval NegInf (RootOf p n)) =
      fromInteger $ AReal.floor'   ((AReal.realRoots p !! n) - 1)
    findSample (Interval (RootOf p n) PosInf) =
      fromInteger $ AReal.ceiling' ((AReal.realRoots p !! n) + 1)
    findSample (Interval (RootOf p1 n1) (RootOf p2 n2)) = assert (pt1 < pt2) $ (pt1 + pt2) / 2
      where
        pt1 = AReal.realRoots p1 !! n1
        pt2 = AReal.realRoots p2 !! n2
    findSample _ = error "findSample: should not happen"

buildSignConf :: (Ord v, Show v, RenderVar v) => [UPolynomial (Coeff v)] -> M v (SignConf (Coeff v))
buildSignConf ps = do
  ps2 <- collectPolynomials (Set.fromList ps)
  let ts = sortBy (comparing deg) (Set.toList ps2)
  foldM (flip refineSignConf) emptySignConf ts

collectPolynomials
  :: (Ord v, Show v, RenderVar v)
  => Set.Set (UPolynomial (Coeff v))
  -> M v (Set.Set (UPolynomial (Coeff v)))
collectPolynomials ps = do
  ps <- go (f ps)
  return ps
  where
    f = Set.filter (\p -> deg p > 0) 

    go ps = do
      let rs1 = [deriv p () | p <- Set.toList ps]
      rs2 <- liftM (map (\(_,_,r) -> r) . catMaybes) $ 
        forM [(p1,p2) | p1 <- Set.toList ps, p2 <- Set.toList ps] $ \(p1,p2) -> do
          ret <- zmod p1 p2
          return ret
      let ps' = f $ Set.unions [ps, Set.fromList rs1, Set.fromList rs2]
      if ps == ps'
        then return ps
        else go ps'

-- TODO: 高次の項から見ていったほうが良い
getHighestNonzeroTerm :: (Ord v, Show v, RenderVar v) => UPolynomial (Coeff v) -> M v (Coeff v, Integer)
getHighestNonzeroTerm p = msum
    [ do forM_ [d+1 .. deg_p] $ \i -> assume (f i) [Zero]
         if (d >= 0)
           then do
             assume (f d) [Pos, Neg]
             return (f d, d)
           else do
             return (0, -1)
    | d <- [-1 .. deg_p]
    ]
  where
    deg_p = deg p
    f i = coeff (mmFromList [((), i)]) p

zmod
  :: forall v. (Ord v, Show v, RenderVar v)
  => UPolynomial (Coeff v)
  -> UPolynomial (Coeff v)
  -> M v (Maybe (Coeff v, Integer, UPolynomial (Coeff v)))
zmod p q = do
  (_, d) <- getHighestNonzeroTerm p
  (_, e) <- getHighestNonzeroTerm q
  if not (d >= e) || 0 >= e
    then return Nothing
    else do
      let p' = fromTerms [(pi, mm) | (pi, mm) <- terms p, mmDegree mm <= d]
          q' = fromTerms [(qi, mm) | (qi, mm) <- terms q, mmDegree mm <= e]
      return $ Just $ mr p' q'

refineSignConf
  :: forall v. (Show v, Ord v, RenderVar v)
  => UPolynomial (Coeff v) -> SignConf (Coeff v) -> M v (SignConf (Coeff v))
refineSignConf p conf = liftM (extendIntervals 0) $ mapM extendPoint conf
  where 
    extendPoint
      :: (Cell (Coeff v), Map.Map (UPolynomial (Coeff v)) Sign)
      -> M v (Cell (Coeff v), Map.Map (UPolynomial (Coeff v)) Sign)
    extendPoint (Point pt, m) = do
      s <- signAt pt m
      return (Point pt, Map.insert p s m)
    extendPoint x = return x
 
    extendIntervals
      :: Int
      -> [(Cell (Coeff v), Map.Map (UPolynomial (Coeff v)) Sign)]
      -> [(Cell (Coeff v), Map.Map (UPolynomial (Coeff v)) Sign)]
    extendIntervals !n (pt1@(Point _, m1) : (Interval lb ub, m) : pt2@(Point _, m2) : xs) =
      pt1 : ys ++ extendIntervals n2 (pt2 : xs)
      where
        s1 = m1 Map.! p
        s2 = m2 Map.! p
        n1 = if s1 == Zero then n+1 else n
        root = RootOf p n1
        (ys, n2)
           | s1 == s2   = ( [ (Interval lb ub, Map.insert p s1 m) ], n1 )
           | s1 == Zero = ( [ (Interval lb ub, Map.insert p s2 m) ], n1 )
           | s2 == Zero = ( [ (Interval lb ub, Map.insert p s1 m) ], n1 )
           | otherwise  = ( [ (Interval lb root, Map.insert p s1   m)
                            , (Point root,       Map.insert p Zero m)
                            , (Interval root ub, Map.insert p s2   m)
                            ]
                          , n1 + 1
                          )
    extendIntervals _ xs = xs
 
    signAt :: Point (Coeff v) -> Map.Map (UPolynomial (Coeff v)) Sign -> M v Sign
    signAt PosInf _ = do
      (c,_) <- getHighestNonzeroTerm p
      signCoeff c
    signAt NegInf _ = do
      (c,d) <- getHighestNonzeroTerm p
      if even d
        then signCoeff c
        else liftM signNegate $ signCoeff c
    signAt (RootOf q _) m = do
      Just (bm,k,r) <- zmod p q
      s1 <- if deg r > 0
            then return $ m Map.! r
            else signCoeff $ coeff mmOne r
      s2 <- signCoeff bm
      return $ signDiv s1 (signExp s2 k)

    signCoeff :: Coeff v -> M v Sign
    signCoeff c =
      msum [ assume c [s] >> return s
           | s <- [Neg, Zero, Pos]
           ]

evalCell :: Ord v => Model v -> Cell (Coeff v) -> Cell Rational
evalCell m (Point pt)         = Point $ evalPoint m pt
evalCell m (Interval pt1 pt2) = Interval (evalPoint m pt1) (evalPoint m pt2)

evalPoint :: Ord v => Model v -> Point (Coeff v) -> Point Rational
evalPoint m NegInf = NegInf
evalPoint m PosInf = PosInf
evalPoint m (RootOf p n) =
  RootOf (AReal.simpARealPoly $ mapCoeff (eval (m Map.!) . mapCoeff fromRational) p) n

-- ---------------------------------------------------------------------------

showDNF :: (Ord v, Show v, RenderVar v) => DNF (Coeff v, Sign) -> String
showDNF (DNF xss) = intercalate " | " [showConj xs | xs <- xss]
  where
    showConj xs = "(" ++ intercalate " & " [f p s | (p,s) <- xs] ++ ")"
    f p s = render p ++ g s
    g Zero = " = 0"
    g Pos  = " > 0"
    g Neg  = " < 0"

dumpSignConf
  :: forall v.
     (Ord v, RenderVar v, Show v)
  => [(SignConf (Coeff v), Map.Map (Coeff v) [Sign])]
  -> IO ()
dumpSignConf x = 
  forM_ x $ \(conf, as) -> do
    putStrLn "============"
    mapM_ putStrLn $ showSignConf conf
    forM_  (Map.toList as) $ \(p, sign) ->
      printf "%s %s\n" (render p) (show sign)

-- ---------------------------------------------------------------------------

test_project :: DNF (Coeff Int, Sign)
test_project = fst $ project [(p', Zero)]
  where
    a = var 0
    b = var 1
    c = var 2
    x = var 3
    p :: Polynomial Rational Int
    p = a*x^(2::Int) + b*x + c
    p' = asPolynomialOf p 3

test_project_print :: IO ()
test_project_print = putStrLn $ showDNF $ test_project

test_project_2 = project [(p, Zero), (x, Pos)]
  where
    x = var ()
    p :: UPolynomial (Coeff Int)
    p = x^(2::Int) + 4*x - 10

test_collectPolynomials :: [(Set.Set (UPolynomial (Coeff Int)), Map.Map (Coeff Int) [Sign])]
test_collectPolynomials = runM $ collectPolynomials (Set.singleton p')
  where
    a = var 0
    b = var 1
    c = var 2
    x = var 3
    p :: Polynomial Rational Int
    p = a*x^(2::Int) + b*x + c
    p' = asPolynomialOf p 3

test_collectPolynomials_print :: IO ()
test_collectPolynomials_print = do
  forM_ test_collectPolynomials $ \(ps,s) -> do
    putStrLn "============"
    mapM_ (putStrLn . render) (Set.toList ps)
    forM_  (Map.toList s) $ \(p, sign) ->
      printf "%s %s\n" (render p) (show sign)

test_buildSignConf :: [(SignConf (Coeff Int), Map.Map (Coeff Int) [Sign])]
test_buildSignConf = runM $ buildSignConf [asPolynomialOf p 3]
  where
    a = var 0
    b = var 1
    c = var 2
    x = var 3
    p :: Polynomial Rational Int
    p = a*x^(2::Int) + b*x + c

test_buildSignConf_print :: IO ()
test_buildSignConf_print = dumpSignConf test_buildSignConf

test_buildSignConf_2 :: [(SignConf (Coeff Int), Map.Map (Coeff Int) [Sign])]
test_buildSignConf_2 = runM $ buildSignConf [asPolynomialOf p 0 | p <- ps]
  where
    x = var 0
    ps :: [Polynomial Rational Int]
    ps = [x + 1, -2*x + 3, x]

test_buildSignConf_2_print :: IO ()
test_buildSignConf_2_print = dumpSignConf test_buildSignConf_2

test_buildSignConf_3 :: [(SignConf (Coeff Int), Map.Map (Coeff Int) [Sign])]
test_buildSignConf_3 = runM $ buildSignConf [asPolynomialOf p 0 | p <- ps]
  where
    x = var 0
    ps :: [Polynomial Rational Int]
    ps = [x, 2*x]

test_buildSignConf_3_print :: IO ()
test_buildSignConf_3_print = dumpSignConf test_buildSignConf_3

-- ---------------------------------------------------------------------------