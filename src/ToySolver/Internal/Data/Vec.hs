{-# LANGUAGE BangPatterns, FlexibleContexts, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  ToySolver.Internal.Data.Vec
-- Copyright   :  (c) Masahiro Sakai 2014
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  provisional
-- Portability :  non-portable (BangPatterns, FlexibleContexts, ScopedTypeVariables)
--
-- Simple 1-dimentional resizable array
--
-----------------------------------------------------------------------------
module ToySolver.Internal.Data.Vec
  (
  -- * Vec type
    GenericVec
  , Vec
  , UVec
  , Index

  -- * Constructors
  , new
  , clone

  -- * Operators
  , getSize
  , read
  , write
  , unsafeRead
  , unsafeWrite
  , resize
  , growTo
  , push
  , unsafePop
  , clear
  , getElems

  -- * Low-level operators
  , getArray
  , getCapacity
  , resizeCapacity
  ) where

import Prelude hiding (read)

import Control.Loop
import Control.Monad
import Data.Ix
import qualified Data.Array.Base as A
import qualified Data.Array.IO as A
import Data.IORef
import ToySolver.Internal.Data.IOURef

data GenericVec a e = GenericVec {-# UNPACK #-} !(IOURef Int) {-# UNPACK #-} !(IORef (a Index e))
  deriving Eq

type Vec e = GenericVec A.IOArray e
type UVec e = GenericVec A.IOUArray e

type Index = Int

new :: A.MArray a e IO => IO (GenericVec a e)
new = do
  sizeRef <- newIOURef 0
  arrayRef <- newIORef =<< A.newArray_ (0,-1)
  return $ GenericVec sizeRef arrayRef

{- INLINE getSize #-}
-- | Get the internal representation array
getSize :: A.MArray a e IO => GenericVec a e -> IO Int
getSize (GenericVec sizeRef _) = readIOURef sizeRef

{-# SPECIALIZE read :: Vec e -> Int -> IO e #-}
{-# SPECIALIZE read :: UVec Int -> Int -> IO Int #-}
{-# SPECIALIZE read :: UVec Double -> Int -> IO Double #-}
{-# SPECIALIZE read :: UVec Bool -> Int -> IO Bool #-}
read :: A.MArray a e IO => GenericVec a e -> Int -> IO e
read !v !i = do
  a <- getArray v
  s <- getSize v
  if 0 <= i && i < s then
    A.unsafeRead a i
  else
    error $ "ToySolver.Data.Vec.read: index " ++ show i ++ " out of bounds"

{-# SPECIALIZE write :: Vec e -> Int -> e -> IO () #-}
{-# SPECIALIZE write :: UVec Int -> Int -> Int -> IO () #-}
{-# SPECIALIZE write :: UVec Double -> Int -> Double -> IO () #-}
{-# SPECIALIZE write :: UVec Bool -> Int -> Bool -> IO () #-}
write :: A.MArray a e IO => GenericVec a e -> Int -> e -> IO ()
write !v !i e = do
  a <- getArray v
  s <- getSize v
  if 0 <= i && i < s then
    A.unsafeWrite a i e
  else
    error $ "ToySolver.Data.Vec.write: index " ++ show i ++ " out of bounds"

{-# INLINE unsafeRead #-}
unsafeRead :: A.MArray a e IO => GenericVec a e -> Int -> IO e
unsafeRead !v !i = do
  a <- getArray v
  A.unsafeRead a i

{-# INLINE unsafeWrite #-}
unsafeWrite :: A.MArray a e IO => GenericVec a e -> Int -> e -> IO ()
unsafeWrite !v !i e = do
  a <- getArray v
  A.unsafeWrite a i e

{-# SPECIALIZE resize :: Vec e -> Int -> IO () #-}
{-# SPECIALIZE resize :: UVec Int -> Int -> IO () #-}
{-# SPECIALIZE resize :: UVec Double -> Int -> IO () #-}
{-# SPECIALIZE resize :: UVec Bool -> Int -> IO () #-}
resize :: A.MArray a e IO => GenericVec a e -> Int -> IO ()
resize v@(GenericVec sizeRef arrayRef) !n = do
  a <- getArray v
  capa <- getCapacity v
  unless (n <= capa) $ do
    let capa' = max 2 (capa * 3 `div` 2)
    a' <- A.newArray_ (0, capa'-1)
    copyTo a a' (0,capa-1)
    writeIORef arrayRef a'
  writeIOURef sizeRef n

{-# SPECIALIZE growTo :: Vec e -> Int -> IO () #-}
{-# SPECIALIZE growTo :: UVec Int -> Int -> IO () #-}
{-# SPECIALIZE growTo :: UVec Double -> Int -> IO () #-}
{-# SPECIALIZE growTo :: UVec Bool -> Int -> IO () #-}
growTo :: A.MArray a e IO => GenericVec a e -> Int -> IO ()
growTo v !n = do
  m <- getSize v
  when (m < n) $ resize v n  

{-# SPECIALIZE push :: Vec e -> e -> IO () #-}
{-# SPECIALIZE push :: UVec Int -> Int -> IO () #-}
{-# SPECIALIZE push :: UVec Double -> Double -> IO () #-}
{-# SPECIALIZE push :: UVec Bool -> Bool -> IO () #-}
push :: A.MArray a e IO => GenericVec a e -> e -> IO ()
push v e = do
  s <- getSize v
  resize v (s+1)
  unsafeWrite v s e

{-# SPECIALIZE unsafePop :: Vec e -> IO e #-}
{-# SPECIALIZE unsafePop :: UVec Int -> IO Int #-}
{-# SPECIALIZE unsafePop :: UVec Double -> IO Double #-}
{-# SPECIALIZE unsafePop :: UVec Bool -> IO Bool #-}
unsafePop :: A.MArray a e IO => GenericVec a e -> IO e
unsafePop v = do
  s <- getSize v
  e <- unsafeRead v (s-1)
  resize v (s-1)
  return e

clear :: A.MArray a e IO => GenericVec a e -> IO ()
clear v = resize v 0

getElems :: A.MArray a e IO => GenericVec a e -> IO [e]
getElems v = do
  s <- getSize v
  forM [0..s-1] $ \i -> unsafeRead v i

{-# SPECIALIZE clone :: Vec e -> IO (Vec e) #-}
{-# SPECIALIZE clone :: UVec Int -> IO (UVec Int) #-}
{-# SPECIALIZE clone :: UVec Double -> IO (UVec Double) #-}
{-# SPECIALIZE clone :: UVec Bool -> IO (UVec Bool) #-}
clone :: A.MArray a e IO => GenericVec a e -> IO (GenericVec a e)
clone (GenericVec sizeRef arrayRef) = do
  a <- readIORef arrayRef
  arrayRef' <- newIORef =<< cloneArray a
  sizeRef'  <- newIOURef =<< readIOURef sizeRef
  return $ GenericVec sizeRef' arrayRef'

{--------------------------------------------------------------------

--------------------------------------------------------------------}

{-# INLINE getArray #-}
-- | Get the internal representation array
getArray :: GenericVec a e -> IO (a Index e)
getArray (GenericVec _ arrayRef) = readIORef arrayRef

{-# INLINE getCapacity #-}
-- | Get the internal representation array
getCapacity :: A.MArray a e IO => GenericVec a e -> IO Int
getCapacity vec = liftM rangeSize $ A.getBounds =<< getArray vec

{-# SPECIALIZE resizeCapacity :: Vec e -> Int -> IO () #-}
{-# SPECIALIZE resizeCapacity :: UVec Int -> Int -> IO () #-}
{-# SPECIALIZE resizeCapacity :: UVec Double -> Int -> IO () #-}
{-# SPECIALIZE resizeCapacity :: UVec Bool -> Int -> IO () #-}
-- | Pre-allocate internal buffer for @n@ elements.
resizeCapacity :: A.MArray a e IO => GenericVec a e -> Int -> IO ()
resizeCapacity (GenericVec sizeRef arrayRef) capa = do
  n <- readIOURef sizeRef
  arr <- readIORef arrayRef
  capa0 <- liftM rangeSize $ A.getBounds arr
  when (capa0 < capa) $ do
    arr' <- A.newArray_ (0, capa-1)
    copyTo arr arr' (0, n-1)
    writeIORef arrayRef arr'

{--------------------------------------------------------------------
  utility
--------------------------------------------------------------------}

{-# INLINE cloneArray #-}
cloneArray :: (A.MArray a e m) => a Index e -> m (a Index e)
cloneArray arr = do
  b <- A.getBounds arr
  arr' <- A.newArray_ b
  copyTo arr arr' b
  return arr'

{-# INLINE copyTo #-}
copyTo :: (A.MArray a e m) => a Index e -> a Index e -> (Index,Index) -> m ()
copyTo fromArr toArr (!lb,!ub) = do
  forLoop lb (<=ub) (+1) $ \i -> do
    val_i <- A.unsafeRead fromArr i
    A.unsafeWrite toArr i val_i
