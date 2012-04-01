-----------------------------------------------------------------------------
-- |
-- Module      :  Linearizer
-- Copyright   :  (c) Masahiro Sakai 2012
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Linearizer
--
-- Note that current implementation is very naïve and introduce many variables.
--
-- Reference:
-- 
-- * [For60] R. Fortet. Application de l'algèbre de Boole en rechercheop
--   opérationelle. Revue Française de Recherche Opérationelle, 4:17–26,
--   1960. 
--
-- * [BM84a] E. Balas and J. B. Mazzola. Nonlinear 0-1 programming:
--   I. Linearization techniques. Mathematical Programming, 30(1):1–21,
--   1984.
-- 
-- * [BM84b] E. Balas and J. B. Mazzola. Nonlinear 0-1 programming:
--   II. Dominance relations and algorithms. Mathematical Programming,
--   30(1):22–45, 1984.
--
-----------------------------------------------------------------------------
module Linearizer
  (
  -- * The @Linearizer@ type
    Linearizer

  -- * Constructor
  , newLinearizer

  -- * Parameters
  , setUsePB

  -- * Operations
  , translate
  ) where

import Control.Monad
import Data.IORef 
import qualified Data.Map as Map
import qualified Data.IntSet as IS
import qualified SAT

-- | Linearizer instance
data Linearizer
  = Linearizer
  { solver   :: !SAT.Solver
  , tableRef :: !(IORef (Map.Map IS.IntSet SAT.Lit))
  , usePBRef :: !(IORef Bool)
  }

-- | Create a @Linearizer@ instance.
newLinearizer :: SAT.Solver -> IO Linearizer
newLinearizer sat = do
  ref1 <- newIORef Map.empty
  ref2 <- newIORef False
  return $ Linearizer sat ref1 ref2

-- | Use /pseudo boolean constraints/ or use only /clauses/.
setUsePB :: Linearizer -> Bool -> IO ()
setUsePB lin usePB = writeIORef (usePBRef lin) usePB

-- | Translate conjunction of literals and return equivalent literal.
translate :: Linearizer -> [SAT.Lit] -> IO SAT.Lit
translate lin ls = do
  let ls2 = IS.fromList ls
  table <- readIORef (tableRef lin)
  case Map.lookup ls2 table of
    Just l -> return l
    Nothing -> do
      let sat = solver lin
      usePB <- readIORef (usePBRef lin)
      v <- SAT.newVar sat
      let ls3 = IS.toList ls2
          n = IS.size ls2
      SAT.addClause sat (v : [SAT.litNot l | l <- ls3])
      if usePB
        then SAT.addPBAtLeast sat ((- fromIntegral n, v) : [(1, SAT.litNot l) | l <- ls3]) 0
        else forM_ ls3 $ \l -> SAT.addClause sat [l, SAT.litNot v]
      writeIORef (tableRef lin) (Map.insert ls2 v table)
      return v
