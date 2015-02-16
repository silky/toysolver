{-# LANGUAGE ScopedTypeVariables, CPP #-}
{-# OPTIONS_GHC -Wall -fno-warn-unused-do-bind #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  toysat
-- Copyright   :  (c) Masahiro Sakai 2012-2014
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  experimental
-- Portability :  non-portable (ScopedTypeVariables, CPP)
--
-- A toy-level SAT solver based on CDCL.
--
-----------------------------------------------------------------------------

module Main where

import Control.Concurrent.Timeout
import Control.Monad
import Control.Exception
import Data.Array.IArray
import qualified Data.ByteString.Lazy as BS
import Data.Default.Class
import qualified Data.Set as Set
import qualified Data.IntSet as IntSet
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Char
import Data.IORef
import Data.List
import Data.Maybe
import Data.Ord
import Data.Ratio
import Data.VectorSpace
import Data.Version
import Data.Time
import System.IO
import System.Environment
import System.Exit
#if !MIN_VERSION_time(1,5,0)
import System.Locale (defaultTimeLocale)
#endif
import System.Console.GetOpt
import System.CPUTime
import System.FilePath
import qualified System.Info as SysInfo
import qualified System.Random as Rand
import qualified Language.CNF.Parse.ParseDIMACS as DIMACS
import Text.Printf
#ifdef __GLASGOW_HASKELL__
import GHC.Environment (getFullArgs)
#endif
#ifdef FORCE_CHAR8
import GHC.IO.Encoding
#endif
#if defined(__GLASGOW_HASKELL__) && MIN_VERSION_base(4,5,0)
import qualified GHC.Stats as Stats
#endif

import ToySolver.Data.ArithRel
import qualified ToySolver.Data.MIP as MIP
import qualified ToySolver.Converter.MaxSAT2WBO as MaxSAT2WBO
import qualified ToySolver.SAT as SAT
import qualified ToySolver.SAT.Types as SAT
import qualified ToySolver.SAT.PBO as PBO
import qualified ToySolver.SAT.Integer as Integer
import qualified ToySolver.SAT.TseitinEncoder as Tseitin
import qualified ToySolver.SAT.MUS as MUS
import qualified ToySolver.SAT.MUS.CAMUS as CAMUS
import qualified ToySolver.SAT.MUS.DAA as DAA
import ToySolver.SAT.Printer
import qualified ToySolver.Text.PBFile as PBFile
import qualified ToySolver.Text.PBFile.Attoparsec as PBFile2
import qualified ToySolver.Text.LPFile as LPFile
import qualified ToySolver.Text.MPSFile as MPSFile
import qualified ToySolver.Text.MaxSAT as MaxSAT
import qualified ToySolver.Text.GCNF as GCNF
import qualified ToySolver.Text.GurobiSol as GurobiSol
import ToySolver.Version
import ToySolver.Internal.Util (showRational, revMapM, revForM)

import UBCSAT

-- ------------------------------------------------------------------------

data Mode = ModeHelp | ModeVersion | ModeSAT | ModeMUS | ModePB | ModeWBO | ModeMaxSAT | ModeMIP

data AllMUSMethod = AllMUSCAMUS | AllMUSDAA

data Options
  = Options
  { optMode          :: Maybe Mode
  , optRestartStrategy :: SAT.RestartStrategy
  , optRestartFirst  :: Int
  , optRestartInc    :: Double
  , optLearningStrategy :: SAT.LearningStrategy
  , optLearntSizeFirst  :: Int
  , optLearntSizeInc    :: Double
  , optCCMin         :: Int
  , optEnablePhaseSaving :: Bool
  , optEnableForwardSubsumptionRemoval :: Bool
  , optEnableBackwardSubsumptionRemoval :: Bool
  , optRandomFreq    :: Double
  , optRandomGen     :: Maybe Rand.StdGen
  , optLinearizerPB  :: Bool
  , optPBHandlerType :: SAT.PBHandlerType
  , optSearchStrategy       :: PBO.SearchStrategy
  , optObjFunVarsHeuristics :: Bool
  , optLocalSearchInitial   :: Bool
  , optAllMUSes :: Bool
  , optAllMUSMethod :: AllMUSMethod
  , optPrintRational :: Bool
  , optCheckModel  :: Bool
  , optTimeout :: Integer
  , optWriteFile :: Maybe FilePath
  , optUBCSAT :: FilePath
  }

instance Default Options where
  def = defaultOptions

defaultOptions :: Options
defaultOptions
  = Options
  { optMode          = Nothing
  , optRestartStrategy = SAT.defaultRestartStrategy
  , optRestartFirst  = SAT.defaultRestartFirst
  , optRestartInc    = SAT.defaultRestartInc
  , optLearningStrategy = SAT.defaultLearningStrategy
  , optLearntSizeFirst  = SAT.defaultLearntSizeFirst
  , optLearntSizeInc    = SAT.defaultLearntSizeInc
  , optCCMin         = SAT.defaultCCMin
  , optEnablePhaseSaving = SAT.defaultEnablePhaseSaving
  , optEnableForwardSubsumptionRemoval = SAT.defaultEnableForwardSubsumptionRemoval
  , optRandomFreq    = SAT.defaultRandomFreq
  , optRandomGen     = Nothing
  , optLinearizerPB  = False
  , optPBHandlerType = SAT.defaultPBHandlerType
  , optEnableBackwardSubsumptionRemoval = SAT.defaultEnableBackwardSubsumptionRemoval
  , optSearchStrategy       = PBO.defaultSearchStrategy
  , optObjFunVarsHeuristics = PBO.defaultEnableObjFunVarsHeuristics
  , optLocalSearchInitial   = False
  , optAllMUSes = False
  , optAllMUSMethod = AllMUSCAMUS
  , optPrintRational = False  
  , optCheckModel = False
  , optTimeout = 0
  , optWriteFile = Nothing
  , optUBCSAT = "ubcsat"
  }

options :: [OptDescr (Options -> Options)]
options =
    [ Option ['h'] ["help"]   (NoArg (\opt -> opt{ optMode = Just ModeHelp   })) "show help"
    , Option [] ["version"]   (NoArg (\opt -> opt{ optMode = Just ModeVersion})) "show version"

    , Option []    ["sat"]    (NoArg (\opt -> opt{ optMode = Just ModeSAT    })) "solve boolean satisfiability problem in .cnf file (default)"
    , Option []    ["mus"]    (NoArg (\opt -> opt{ optMode = Just ModeMUS    })) "solve minimally unsatisfiable subset problem in .gcnf or .cnf file"
    , Option []    ["pb"]     (NoArg (\opt -> opt{ optMode = Just ModePB     })) "solve pseudo boolean problem in .opb file"
    , Option []    ["wbo"]    (NoArg (\opt -> opt{ optMode = Just ModeWBO    })) "solve weighted boolean optimization problem in .wbo file"
    , Option []    ["maxsat"] (NoArg (\opt -> opt{ optMode = Just ModeMaxSAT })) "solve MaxSAT problem in .cnf or .wcnf file"
    , Option []    ["lp"]     (NoArg (\opt -> opt{ optMode = Just ModeMIP    })) "solve bounded integer programming problem in .lp or .mps file"

    , Option [] ["restart"]
        (ReqArg (\val opt -> opt{ optRestartStrategy = parseRestartStrategy val }) "<str>")
        "Restart startegy: MiniSAT (default), Armin, Luby."
    , Option [] ["restart-first"]
        (ReqArg (\val opt -> opt{ optRestartFirst = read val }) "<integer>")
        (printf "The initial restart limit. (default %d)" SAT.defaultRestartFirst)
    , Option [] ["restart-inc"]
        (ReqArg (\val opt -> opt{ optRestartInc = read val }) "<real>")
        (printf "The factor with which the restart limit is multiplied in each restart. (default %f)" SAT.defaultRestartInc)
    , Option [] ["learning"]
        (ReqArg (\val opt -> opt{ optLearningStrategy = parseLS val }) "<name>")
        "Leaning scheme: clause (default), hybrid"
    , Option [] ["learnt-size-first"]
        (ReqArg (\val opt -> opt{ optLearntSizeFirst = read val }) "<int>")
        "The initial limit for learnt clauses."
    , Option [] ["learnt-size-inc"]
        (ReqArg (\val opt -> opt{ optLearntSizeInc = read val }) "<real>")
        (printf "The limit for learnt clauses is multiplied with this factor periodically. (default %f)" SAT.defaultLearntSizeInc)
    , Option [] ["ccmin"]
        (ReqArg (\val opt -> opt{ optCCMin = read val }) "<int>")
        (printf "Conflict clause minimization (0=none, 1=local, 2=recursive; default %d)" SAT.defaultCCMin)
    , Option [] ["enable-phase-saving"]
        (NoArg (\opt -> opt{ optEnablePhaseSaving = True }))
        ("Enable phase saving" ++ (if SAT.defaultEnablePhaseSaving then " (default)" else ""))
    , Option [] ["disable-phase-saving"]
        (NoArg (\opt -> opt{ optEnablePhaseSaving = False }))
        ("Disable phase saving" ++ (if SAT.defaultEnablePhaseSaving then "" else " (default)"))
    , Option [] ["enable-forward-subsumption-removal"]
        (NoArg (\opt -> opt{ optEnableForwardSubsumptionRemoval = True }))
        ("Enable forward subumption removal (clauses only)" ++ (if SAT.defaultEnableForwardSubsumptionRemoval then " (default)" else ""))
    , Option [] ["disable-forward-subsumption-removal"]
        (NoArg (\opt -> opt{ optEnableForwardSubsumptionRemoval = False }))
        ("Disable forward subsumption removal (clauses only)" ++ (if SAT.defaultEnableForwardSubsumptionRemoval then "" else " (default)"))
    , Option [] ["enable-backward-subsumption-removal"]
        (NoArg (\opt -> opt{ optEnableBackwardSubsumptionRemoval = True }))
        ("Enable backward subsumption removal." ++ (if SAT.defaultEnableBackwardSubsumptionRemoval then " (default)" else ""))
    , Option [] ["disable-backward-subsumption-removal"]
        (NoArg (\opt -> opt{ optEnableBackwardSubsumptionRemoval = False }))
        ("Disable backward subsumption removal." ++ (if SAT.defaultEnableBackwardSubsumptionRemoval then "" else " (default)"))

    , Option [] ["random-freq"]
        (ReqArg (\val opt -> opt{ optRandomFreq = read val }) "<0..1>")
        (printf "The frequency with which the decision heuristic tries to choose a random variable (default %f)" SAT.defaultRandomFreq)
    , Option [] ["random-seed"]
        (ReqArg (\val opt -> opt{ optRandomGen = Just (Rand.mkStdGen (read val)) }) "<int>")
        "random seed used by the random variable selection"
    , Option [] ["random-gen"]
        (ReqArg (\val opt -> opt{ optRandomGen = Just (read val) }) "<str>")
        "another way of specifying random seed used by the random variable selection"

    , Option [] ["linearizer-pb"]
        (NoArg (\opt -> opt{ optLinearizerPB = True }))
        "Use PB constraint in linearization."

    , Option [] ["pb-handler"]
        (ReqArg (\val opt -> opt{ optPBHandlerType = parsePBHandler val }) "<name>")
        "PB constraint handler: counter (default), pueblo"

    , Option [] ["search"]
        (ReqArg (\val opt -> opt{ optSearchStrategy = parseSearch val }) "<str>")
        "Search algorithm used in optimization; linear (default), binary, adaptive, unsat, msu4, bc, bcd, bcd2"
    , Option [] ["objfun-heuristics"]
        (NoArg (\opt -> opt{ optObjFunVarsHeuristics = True }))
        "Enable heuristics for polarity/activity of variables in objective function (default)"
    , Option [] ["no-objfun-heuristics"]
        (NoArg (\opt -> opt{ optObjFunVarsHeuristics = False }))
        "Disable heuristics for polarity/activity of variables in objective function"
    , Option [] ["ls-initial"]
        (NoArg (\opt -> opt{ optLocalSearchInitial = True }))
        "Use local search (currently UBCSAT) for finding initial solution"

    , Option [] ["all-mus"]
        (NoArg (\opt -> opt{ optAllMUSes = True }))
        "enumerate all MUSes"
    , Option [] ["all-mus-daa"]
        (NoArg (\opt -> opt{ optAllMUSes = True, optAllMUSMethod = AllMUSDAA }))
        "enumerate all MUSes using DAA instead of CAMUS (experimental option)"

    , Option [] ["print-rational"]
        (NoArg (\opt -> opt{ optPrintRational = True }))
        "print rational numbers instead of decimals"
    , Option ['w'] []
        (ReqArg (\val opt -> opt{ optWriteFile = Just val }) "<filename>")
        "write model to filename in Gurobi .sol format"

    , Option [] ["check-model"]
        (NoArg (\opt -> opt{ optCheckModel = True }))
        "check model for debug"

    , Option [] ["timeout"]
        (ReqArg (\val opt -> opt{ optTimeout = read val }) "<int>")
        "Kill toysat after given number of seconds (default 0 (no limit))"

    , Option [] ["with-ubcsat"]
        (ReqArg (\val opt -> opt{ optUBCSAT = val }) "<PATH>")
        "give the path to the UBCSAT command"
    ]
  where
    parseRestartStrategy s =
      case map toLower s of
        "minisat" -> SAT.MiniSATRestarts
        "armin" -> SAT.ArminRestarts
        "luby" -> SAT.LubyRestarts
        _ -> error (printf "unknown restart strategy \"%s\"" s)

    parseSearch s =
      case map toLower s of
        "linear"   -> PBO.LinearSearch
        "binary"   -> PBO.BinarySearch
        "adaptive" -> PBO.AdaptiveSearch
        "unsat"    -> PBO.UnsatBased
        "msu4"     -> PBO.MSU4
        "bc"       -> PBO.BC
        "bcd"      -> PBO.BCD
        "bcd2"     -> PBO.BCD2
        _ -> error (printf "unknown search strategy \"%s\"" s)

    parseLS s =
      case map toLower s of
        "clause" -> SAT.LearningClause
        "hybrid" -> SAT.LearningHybrid
        _ -> error (printf "unknown learning strategy \"%s\"" s)

    parsePBHandler s =
      case map toLower s of
        "counter" -> SAT.PBHandlerTypeCounter
        "pueblo"  -> SAT.PBHandlerTypePueblo
        _ -> error (printf "unknown PB constraint handler %s" s)

main :: IO ()
main = do
#ifdef FORCE_CHAR8
  setLocaleEncoding char8
  setForeignEncoding char8
  setFileSystemEncoding char8
#endif

  startCPU <- getCPUTime
  startWC  <- getCurrentTime
  args <- getArgs
  case getOpt Permute options args of
    (_,_,errs@(_:_)) -> do
      mapM_ putStrLn errs
      exitFailure

    (o,args2,[]) -> do
      let opt = foldl (flip id) def o      
          mode =
            case optMode opt of
              Just m  -> m
              Nothing ->
                case args2 of
                  [] -> ModeHelp
                  fname : _ ->
                    case map toLower (takeExtension fname) of
                      ".cnf"  -> ModeSAT
                      ".gcnf" -> ModeMUS
                      ".opb"  -> ModePB
                      ".wbo"  -> ModeWBO
                      ".wcnf" -> ModeMaxSAT
                      ".lp"   -> ModeMIP
                      ".mps"  -> ModeMIP
                      _ -> ModeSAT

      case mode of
        ModeHelp    -> showHelp stdout
        ModeVersion -> hPutStrLn stdout (showVersion version)
        _ -> do
          printSysInfo
#ifdef __GLASGOW_HASKELL__
          fullArgs <- getFullArgs
#else
          let fullArgs = args
#endif
          putCommentLine $ printf "command line = %s" (show fullArgs)

          let timelim = optTimeout opt * 10^(6::Int)
    
          ret <- timeout (if timelim > 0 then timelim else (-1)) $ do
             solver <- newSolver opt
             case mode of
               ModeHelp    -> showHelp stdout
               ModeVersion -> hPutStrLn stdout (showVersion version)
               ModeSAT     -> mainSAT opt solver args2
               ModeMUS     -> mainMUS opt solver args2
               ModePB      -> mainPB opt solver args2
               ModeWBO     -> mainWBO opt solver args2
               ModeMaxSAT  -> mainMaxSAT opt solver args2
               ModeMIP     -> mainMIP opt solver args2
    
          when (isNothing ret) $ do
            putCommentLine "TIMEOUT"
          endCPU <- getCPUTime
          endWC  <- getCurrentTime
          putCommentLine $ printf "total CPU time = %.3fs" (fromIntegral (endCPU - startCPU) / 10^(12::Int) :: Double)
          putCommentLine $ printf "total wall clock time = %.3fs" (realToFrac (endWC `diffUTCTime` startWC) :: Double)
          printGCStat

printGCStat :: IO ()
#if defined(__GLASGOW_HASKELL__) && MIN_VERSION_base(4,5,0)
printGCStat = do
#if MIN_VERSION_base(4,6,0)
  b <- Stats.getGCStatsEnabled
  when b $ do
#else
  do
#endif
    stat <- Stats.getGCStats
    putCommentLine "GCStats:"
    putCommentLine $ printf "  bytesAllocated = %d"         $ Stats.bytesAllocated stat
    putCommentLine $ printf "  numGcs = %d"                 $ Stats.numGcs stat
    putCommentLine $ printf "  maxBytesUsed = %d"           $ Stats.maxBytesUsed stat
    putCommentLine $ printf "  numByteUsageSamples = %d"    $ Stats.numByteUsageSamples stat
    putCommentLine $ printf "  cumulativeBytesUsed = %d"    $ Stats.cumulativeBytesUsed stat
    putCommentLine $ printf "  bytesCopied = %d"            $ Stats.bytesCopied stat
    putCommentLine $ printf "  currentBytesUsed = %d"       $ Stats.currentBytesUsed stat
    putCommentLine $ printf "  currentBytesSlop = %d"       $ Stats.currentBytesSlop stat
    putCommentLine $ printf "  maxBytesSlop = %d"           $ Stats.maxBytesSlop stat
    putCommentLine $ printf "  peakMegabytesAllocated = %d" $ Stats.peakMegabytesAllocated stat
    putCommentLine $ printf "  mutatorCpuSeconds = %5.2f"   $ Stats.mutatorCpuSeconds stat
    putCommentLine $ printf "  mutatorWallSeconds = %5.2f"  $ Stats.mutatorWallSeconds stat
    putCommentLine $ printf "  gcCpuSeconds = %5.2f"        $ Stats.gcCpuSeconds stat
    putCommentLine $ printf "  gcWallSeconds = %5.2f"       $ Stats.gcWallSeconds stat
    putCommentLine $ printf "  cpuSeconds = %5.2f"          $ Stats.cpuSeconds stat
    putCommentLine $ printf "  wallSeconds = %5.2f"         $ Stats.wallSeconds stat
#if MIN_VERSION_base(4,6,0)
    putCommentLine $ printf "  parTotBytesCopied = %d"      $ Stats.parTotBytesCopied stat
#else
    putCommentLine $ printf "  parAvgBytesCopied = %d"      $ Stats.parAvgBytesCopied stat
#endif
    putCommentLine $ printf "  parMaxBytesCopied = %d"      $ Stats.parMaxBytesCopied stat
#else
printGCStat = return ()
#endif

showHelp :: Handle -> IO ()
showHelp h = hPutStrLn h (usageInfo header options)

header :: String
header = unlines
  [ "Usage:"
  , "  toysat [OPTION]... [file.cnf|-]"
  , "  toysat [OPTION]... --mus [file.gcnf|-]"
  , "  toysat [OPTION]... --pb [file.opb|-]"
  , "  toysat [OPTION]... --wbo [file.wbo|-]"
  , "  toysat [OPTION]... --maxsat [file.cnf|file.wcnf|-]"
  , "  toysat [OPTION]... --lp [file.lp|file.mps|-]"
  , ""
  , "Options:"
  ]

printSysInfo :: IO ()
printSysInfo = do
  tm <- getZonedTime
  putCommentLine $ printf "%s" (formatTime defaultTimeLocale "%FT%X%z" tm)
  putCommentLine $ printf "arch = %s" SysInfo.arch
  putCommentLine $ printf "os = %s" SysInfo.os
  putCommentLine $ printf "compiler = %s %s" SysInfo.compilerName (showVersion SysInfo.compilerVersion)
  putCommentLine "packages:"
  forM_ packageVersions $ \(package, ver) -> do
    putCommentLine $ printf "  %s-%s" package ver

putCommentLine :: String -> IO ()
putCommentLine s = do
  putStr "c "
  putStrLn s
  hFlush stdout

putSLine :: String -> IO ()
putSLine  s = do
  putStr "s "
  putStrLn s
  hFlush stdout

putOLine :: String -> IO ()
putOLine  s = do
  putStr "o "
  putStrLn s
  hFlush stdout

newSolver :: Options -> IO SAT.Solver
newSolver opts = do
  solver <- SAT.newSolver
  SAT.setRestartStrategy solver (optRestartStrategy opts)
  SAT.setRestartFirst    solver (optRestartFirst opts)
  SAT.setRestartInc      solver (optRestartInc opts)
  SAT.setLearntSizeFirst solver (optLearntSizeFirst opts)
  SAT.setLearntSizeInc   solver (optLearntSizeInc opts)
  SAT.setCCMin           solver (optCCMin opts)
  SAT.setRandomFreq      solver (optRandomFreq opts)
  case optRandomGen opts of
    Nothing -> return ()
    Just gen -> SAT.setRandomGen solver gen
  do gen <- SAT.getRandomGen solver
     putCommentLine $ "use --random-gen=" ++ show (show gen) ++ " option to reproduce the execution"
  SAT.setLearningStrategy solver (optLearningStrategy opts)
  SAT.setEnablePhaseSaving solver (optEnablePhaseSaving opts)
  SAT.setEnableForwardSubsumptionRemoval solver (optEnableForwardSubsumptionRemoval opts)
  SAT.setEnableBackwardSubsumptionRemoval solver (optEnableBackwardSubsumptionRemoval opts)
  SAT.setPBHandlerType solver (optPBHandlerType opts)
  SAT.setLogger solver putCommentLine
  SAT.setCheckModel solver (optCheckModel opts)
  return solver

-- ------------------------------------------------------------------------

mainSAT :: Options -> SAT.Solver -> [String] -> IO ()
mainSAT opt solver args = do
  ret <- case args of
           ["-"]   -> fmap (DIMACS.parseByteString "-") $ BS.hGetContents stdin
           [fname] -> DIMACS.parseFile fname
           _ -> showHelp stderr >> exitFailure
  case ret of
    Left err -> hPrint stderr err >> exitFailure
    Right cnf -> solveSAT opt solver cnf

solveSAT :: Options -> SAT.Solver -> DIMACS.CNF -> IO ()
solveSAT opt solver cnf = do
  putCommentLine $ printf "#vars %d" (DIMACS.numVars cnf)
  putCommentLine $ printf "#constraints %d" (DIMACS.numClauses cnf)
  SAT.newVars_ solver (DIMACS.numVars cnf)
  forM_ (DIMACS.clauses cnf) $ \clause ->
    SAT.addClause solver (elems clause)
  result <- SAT.solve solver
  putSLine $ if result then "SATISFIABLE" else "UNSATISFIABLE"
  when result $ do
    m <- SAT.getModel solver
    satPrintModel stdout m (DIMACS.numVars cnf)
    writeSOLFile opt m Nothing (DIMACS.numVars cnf)

-- ------------------------------------------------------------------------

mainMUS :: Options -> SAT.Solver -> [String] -> IO ()
mainMUS opt solver args = do
  gcnf <- case args of
           ["-"]   -> do
             s <- hGetContents stdin
             case GCNF.parseString s of
               Left err   -> hPutStrLn stderr err >> exitFailure
               Right gcnf -> return gcnf
           [fname] -> do
             ret <- GCNF.parseFile fname
             case ret of
               Left err   -> hPutStrLn stderr err >> exitFailure
               Right gcnf -> return gcnf
           _ -> showHelp stderr >> exitFailure
  solveMUS opt solver gcnf

solveMUS :: Options -> SAT.Solver -> GCNF.GCNF -> IO ()
solveMUS opt solver gcnf = do
  putCommentLine $ printf "#vars %d" (GCNF.numVars gcnf)
  putCommentLine $ printf "#constraints %d" (GCNF.numClauses gcnf)
  putCommentLine $ printf "#groups %d" (GCNF.lastGroupIndex gcnf)

  SAT.resizeVarCapacity solver (GCNF.numVars gcnf + GCNF.lastGroupIndex gcnf)
  SAT.newVars_ solver (GCNF.numVars gcnf)

  tbl <- forM [1 .. GCNF.lastGroupIndex gcnf] $ \i -> do
    sel <- SAT.newVar solver
    return (i, sel)
  let idx2sel :: Array Int SAT.Var
      idx2sel = array (1, GCNF.lastGroupIndex gcnf) tbl
      selrng  = if null tbl then (0,-1) else (snd $ head tbl, snd $ last tbl)
      sel2idx :: Array SAT.Lit Int
      sel2idx = array selrng [(sel, idx) | (idx, sel) <- tbl]

  forM_ (GCNF.clauses gcnf) $ \(idx, clause) ->
    if idx==0
    then SAT.addClause solver clause
    else SAT.addClause solver (- (idx2sel ! idx) : clause)

  result <- SAT.solveWith solver (map (idx2sel !) [1..GCNF.lastGroupIndex gcnf])
  putSLine $ if result then "SATISFIABLE" else "UNSATISFIABLE"
  if result
    then do
      m <- SAT.getModel solver
      satPrintModel stdout m (GCNF.numVars gcnf)
      writeSOLFile opt m Nothing (GCNF.numVars gcnf)
    else do
      if not (optAllMUSes opt)
        then do
          let opt2 = def
                     { MUS.optLogger = putCommentLine
                     , MUS.optLitPrinter = \lit ->
                         show (sel2idx ! lit)
                     }
          mus <- MUS.findMUSAssumptions solver opt2
          let mus2 = sort $ map (sel2idx !) $ IntSet.toList mus
          musPrintSol stdout mus2
        else do
          counter <- newIORef 1
          let opt2 = def
                     { CAMUS.optLogger = putCommentLine
                     , CAMUS.optOnMCSFound = \mcs -> do
                         let mcs2 = sort $ map (sel2idx !) $ IntSet.toList mcs
                         putCommentLine $ "MCS found: " ++ show mcs2
                     , CAMUS.optOnMUSFound = \mus -> do
                         i <- readIORef counter
                         modifyIORef' counter (+1)
                         putCommentLine $ "MUS #" ++ show (i :: Int)
                         let mus2 = sort $ map (sel2idx !) $ IntSet.toList mus
                         musPrintSol stdout mus2
                     }
          case optAllMUSMethod opt of
            AllMUSCAMUS -> CAMUS.allMUSAssumptions solver (map snd tbl) opt2
            AllMUSDAA   -> DAA.allMUSAssumptions solver (map snd tbl) opt2
          return ()

-- ------------------------------------------------------------------------

mainPB :: Options -> SAT.Solver -> [String] -> IO ()
mainPB opt solver args = do
  ret <- case args of
           ["-"]   -> fmap PBFile.parseOPBByteString $ BS.hGetContents stdin
           [fname] -> PBFile2.parseOPBFile fname
           _ -> showHelp stderr >> exitFailure
  case ret of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right formula -> solvePB opt solver formula Nothing

solvePB :: Options -> SAT.Solver -> PBFile.Formula -> Maybe SAT.Model -> IO ()
solvePB opt solver formula initialModel = do
  let nv = PBFile.pbNumVars formula
      nc = PBFile.pbNumConstraints formula
  putCommentLine $ printf "#vars %d" nv
  putCommentLine $ printf "#constraints %d" nc

  SAT.newVars_ solver nv
  enc <- Tseitin.newEncoder solver
  Tseitin.setUsePB enc (optLinearizerPB opt)

  forM_ (PBFile.pbConstraints formula) $ \(lhs, op, rhs) -> do
    lhs' <- pbConvSum enc lhs
    case op of
      PBFile.Ge -> SAT.addPBAtLeast solver lhs' rhs
      PBFile.Eq -> SAT.addPBExactly solver lhs' rhs

  case PBFile.pbObjectiveFunction formula of
    Nothing -> do
      result <- SAT.solve solver
      putSLine $ if result then "SATISFIABLE" else "UNSATISFIABLE"
      when result $ do
        m <- SAT.getModel solver
        pbPrintModel stdout m nv
        writeSOLFile opt m Nothing nv

    Just obj' -> do
      obj'' <- pbConvSum enc obj'

      nv' <- SAT.nVars solver
      defs <- Tseitin.getDefinitions enc
      let extendModel :: SAT.Model -> SAT.Model
          extendModel m = array (1,nv') (assocs a)
            where
              -- Use BOXED array to tie the knot
              a :: Array SAT.Var Bool
              a = array (1,nv') $ assocs m ++ [(v, Tseitin.evalFormula a phi) | (v,phi) <- defs]

      pbo <- PBO.newOptimizer solver obj''
      setupOptimizer pbo opt
      PBO.setOnUpdateBestSolution pbo $ \_ val -> putOLine (show val)
      PBO.setOnUpdateLowerBound pbo $ \lb -> do
        putCommentLine $ printf "lower bound updated to %d" lb

      case initialModel of
        Nothing -> return ()
        Just m -> PBO.addSolution pbo (extendModel m)

      finally (PBO.optimize pbo) $ do
        ret <- PBO.getBestSolution pbo
        case ret of
          Nothing -> do
            b <- PBO.isUnsat pbo
            if b
              then putSLine "UNSATISFIABLE"
              else putSLine "UNKNOWN"
          Just (m, val) -> do
            b <- PBO.isOptimum pbo
            if b
              then putSLine "OPTIMUM FOUND"
              else putSLine "SATISFIABLE"
            pbPrintModel stdout m nv
            writeSOLFile opt m (Just val) nv

pbConvSum :: Tseitin.Encoder -> PBFile.Sum -> IO SAT.PBLinSum
pbConvSum enc = revMapM f
  where
    f (w,ls) = do
      l <- Tseitin.encodeConj enc ls
      return (w,l)

evalPBConstraint :: SAT.IModel m => m -> PBFile.Constraint -> Bool
evalPBConstraint m (lhs,op,rhs) = op' lhs' rhs
  where
    op' = case op of
            PBFile.Ge -> (>=)
            PBFile.Eq -> (==)
    lhs' = sum [if and [SAT.evalLit m lit | lit <- tm] then c else 0 | (c,tm) <- lhs]

setupOptimizer :: PBO.Optimizer -> Options -> IO ()
setupOptimizer pbo opt = do
  PBO.setEnableObjFunVarsHeuristics pbo $ optObjFunVarsHeuristics opt
  PBO.setSearchStrategy pbo $ optSearchStrategy opt
  PBO.setLogger pbo putCommentLine

-- ------------------------------------------------------------------------

mainWBO :: Options -> SAT.Solver -> [String] -> IO ()
mainWBO opt solver args = do
  ret <- case args of
           ["-"]   -> fmap PBFile.parseWBOByteString $ BS.hGetContents stdin
           [fname] -> PBFile2.parseWBOFile fname
           _ -> showHelp stderr >> exitFailure
  case ret of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right formula -> solveWBO opt solver False formula Nothing

solveWBO :: Options -> SAT.Solver -> Bool -> PBFile.SoftFormula -> Maybe SAT.Model -> IO ()
solveWBO opt solver isMaxSat formula initialModel = do
  let nv = PBFile.wboNumVars formula
      nc = PBFile.wboNumConstraints formula
  putCommentLine $ printf "#vars %d" nv
  putCommentLine $ printf "#constraints %d" nc

  SAT.resizeVarCapacity solver (nv + length [() | (Just _, _) <- PBFile.wboConstraints formula])
  SAT.newVars_ solver nv
  enc <- Tseitin.newEncoder solver
  Tseitin.setUsePB enc (optLinearizerPB opt)

  defsRef <- newIORef []

  obj <- liftM concat $ revForM (PBFile.wboConstraints formula) $ \(cost, constr@(lhs, op, rhs)) -> do
    lhs' <- pbConvSum enc lhs
    case cost of
      Nothing -> do
        case op of
          PBFile.Ge -> SAT.addPBAtLeast solver lhs' rhs
          PBFile.Eq -> SAT.addPBExactly solver lhs' rhs
        return []
      Just cval -> do
        sel <-
          case op of
            PBFile.Ge -> do
              case lhs' of
                [(1,l)] | rhs == 1 -> return l
                _ -> do
                  sel <- SAT.newVar solver
                  SAT.addPBAtLeastSoft solver sel lhs' rhs
                  modifyIORef defsRef ((sel, constr) : )
                  return sel
            PBFile.Eq -> do
              sel <- SAT.newVar solver
              SAT.addPBExactlySoft solver sel lhs' rhs
              modifyIORef defsRef ((sel, constr) : )
              return sel
        return [(cval, SAT.litNot sel)]

  case PBFile.wboTopCost formula of
    Nothing -> return ()
    Just c -> SAT.addPBAtMost solver obj (c-1)

  nv' <- SAT.nVars solver
  defs1 <- Tseitin.getDefinitions enc
  defs2 <- readIORef defsRef
  let extendModel :: SAT.Model -> SAT.Model
      extendModel m = array (1,nv') (assocs a)
        where
          -- Use BOXED array to tie the knot
          a :: Array SAT.Var Bool
          a = array (1,nv') $
                assocs m ++
                [(v, Tseitin.evalFormula a phi) | (v, phi) <- defs1] ++
                [(v, evalPBConstraint a constr) | (v, constr) <- defs2]

  pbo <- PBO.newOptimizer solver obj
  setupOptimizer pbo opt
  PBO.setOnUpdateBestSolution pbo $ \_ val -> putOLine (show val)
  PBO.setOnUpdateLowerBound pbo $ \lb -> do
    putCommentLine $ printf "lower bound updated to %d" lb

  case initialModel of
    Nothing -> return ()
    Just m -> PBO.addSolution pbo (extendModel m)

  finally (PBO.optimize pbo) $ do
    ret <- PBO.getBestSolution pbo
    case ret of
      Nothing -> do
        b <- PBO.isUnsat pbo
        if b
          then putSLine "UNSATISFIABLE"
          else putSLine "UNKNOWN"
      Just (m, val) -> do
        b <- PBO.isOptimum pbo
        if b then do
          putSLine "OPTIMUM FOUND"
          pbPrintModel stdout m nv
          writeSOLFile opt m (Just val) nv
        else if not isMaxSat then do
          putSLine "SATISFIABLE"
          pbPrintModel stdout m nv
          writeSOLFile opt m (Just val) nv
        else 
          putSLine "UNKNOWN"

-- ------------------------------------------------------------------------

mainMaxSAT :: Options -> SAT.Solver -> [String] -> IO ()
mainMaxSAT opt solver args = do
  ret <- case args of
           ["-"]   -> liftM MaxSAT.parseByteString BS.getContents
           [fname] -> MaxSAT.parseFile fname
           _ -> showHelp stderr  >> exitFailure
  case ret of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right wcnf -> do
      initialModel <-
        case args of
          [fname] | optLocalSearchInitial opt && or [s `isSuffixOf` map toLower fname | s <- [".cnf", ".wcnf"] ] ->
            UBCSAT.ubcsat (optUBCSAT opt) fname wcnf
          _ -> return Nothing
      solveMaxSAT opt solver wcnf initialModel

solveMaxSAT :: Options -> SAT.Solver -> MaxSAT.WCNF -> Maybe SAT.Model -> IO ()
solveMaxSAT opt solver wcnf initialModel =
  solveWBO opt solver True (MaxSAT2WBO.convert wcnf) initialModel

-- ------------------------------------------------------------------------

mainMIP :: Options -> SAT.Solver -> [String] -> IO ()
mainMIP opt solver args = do
  mip <-
    case args of
      [fname@"-"]   -> do
        s <- hGetContents stdin
        case LPFile.parseString fname s of
          Right mip -> return mip
          Left err ->
            case MPSFile.parseString fname s of
              Right mip -> return mip
              Left err2 -> do
                hPrint stderr err
                hPrint stderr err2
                exitFailure
      [fname] -> do
        ret <- MIP.readFile fname
        case ret of
          Left err -> hPrint stderr err >> exitFailure
          Right mip -> return mip
      _ -> showHelp stderr >> exitFailure
  solveMIP opt solver mip

solveMIP :: Options -> SAT.Solver -> MIP.Problem -> IO ()
solveMIP opt solver mip = do
  if not (Set.null nivs)
    then do
      putCommentLine $ "cannot handle non-integer variables: " ++ intercalate ", " (map MIP.fromVar (Set.toList nivs))
      putSLine "UNKNOWN"
      exitFailure
    else do
      enc <- Tseitin.newEncoder solver
      Tseitin.setUsePB enc (optLinearizerPB opt)

      putCommentLine $ "Loading variables and bounds"
      vmap <- liftM Map.fromList $ revForM (Set.toList ivs) $ \v -> do
        let (lb,ub) = MIP.getBounds mip v
        case (lb,ub) of
          (MIP.Finite lb', MIP.Finite ub') -> do
            v2 <- Integer.newVar solver (ceiling lb') (floor ub')
            return (v,v2)
          _ -> do
            putCommentLine $ "cannot handle unbounded variable: " ++ MIP.fromVar v
            putSLine "UNKNOWN"
            exitFailure

      putCommentLine "Loading constraints"
      forM_ (MIP.constraints mip) $ \c -> do
        let indicator      = MIP.constrIndicator c
            (lhs, op, rhs) = MIP.constrBody c
        let d = foldl' lcm 1 (map denominator  (rhs:[r | MIP.Term r _ <- lhs]))
            lhs' = sumV [asInteger (r * fromIntegral d) *^ product [vmap Map.! v | v <- vs] | MIP.Term r vs <- lhs]
            rhs' = asInteger (rhs * fromIntegral d)
        case indicator of
          Nothing ->
            case op of
              MIP.Le  -> Integer.addConstraint enc $ lhs' .<=. fromInteger rhs'
              MIP.Ge  -> Integer.addConstraint enc $ lhs' .>=. fromInteger rhs'
              MIP.Eql -> Integer.addConstraint enc $ lhs' .==. fromInteger rhs'
          Just (var, val) -> do
            let var' = asBin (vmap Map.! var)
                f sel = do
                  case op of
                    MIP.Le  -> Integer.addConstraintSoft enc sel $ lhs' .<=. fromInteger rhs'
                    MIP.Ge  -> Integer.addConstraintSoft enc sel $ lhs' .>=. fromInteger rhs'
                    MIP.Eql -> Integer.addConstraintSoft enc sel $ lhs' .==. fromInteger rhs'
            case val of
              1 -> f var'
              0 -> f (SAT.litNot var')
              _ -> return ()

      putCommentLine "Loading SOS constraints"
      forM_ (MIP.sosConstraints mip) $ \MIP.SOSConstraint{ MIP.sosType = typ, MIP.sosBody = xs } -> do
        case typ of
          MIP.S1 -> SAT.addAtMost solver (map (asBin . (vmap Map.!) . fst) xs) 1
          MIP.S2 -> do
            let ps = nonAdjacentPairs $ map fst $ sortBy (comparing snd) $ xs
            forM_ ps $ \(x1,x2) -> do
              SAT.addClause solver [SAT.litNot $ asBin $ vmap Map.! v | v <- [x1,x2]]

      let (_label,obj) = MIP.objectiveFunction mip      
          d = foldl' lcm 1 [denominator r | MIP.Term r _ <- obj] *
              (if MIP.dir mip == MIP.OptMin then 1 else -1)
          obj2 = sumV [asInteger (r * fromIntegral d) *^ product [vmap Map.! v | v <- vs] | MIP.Term r vs <- obj]
      (obj3,obj3_c) <- Integer.linearize enc obj2

      let transformObjVal :: Integer -> Rational
          transformObjVal val = fromIntegral (val + obj3_c) / fromIntegral d

          transformModel :: SAT.Model -> Map String Integer
          transformModel m = Map.fromList
            [ (MIP.fromVar v, Integer.eval m (vmap Map.! v)) | v <- Set.toList ivs ]

          printModel :: Map String Integer -> IO ()
          printModel m = do
            forM_ (Map.toList m) $ \(v, val) -> do
              printf "v %s = %d\n" v val
            hFlush stdout

          writeSol :: Map String Integer -> Rational -> IO ()
          writeSol m val = do
            case optWriteFile opt of
              Nothing -> return ()
              Just fname -> do
                writeFile fname (GurobiSol.render (fmap fromInteger m) (Just (fromRational val)))

      pbo <- PBO.newOptimizer solver obj3
      setupOptimizer pbo opt
      PBO.setOnUpdateBestSolution pbo $ \_ val -> do
        putOLine $ showRational (optPrintRational opt) (transformObjVal val)

      finally (PBO.optimize pbo) $ do
        ret <- PBO.getBestSolution pbo
        case ret of
          Nothing -> do
            b <- PBO.isUnsat pbo
            if b
              then putSLine "UNSATISFIABLE"
              else putSLine "UNKNOWN"
          Just (m,val) -> do
            b <- PBO.isOptimum pbo
            if b
              then putSLine "OPTIMUM FOUND"
              else putSLine "SATISFIABLE"
            let m2   = transformModel m
                val2 = transformObjVal val
            printModel m2
            writeSol m2 val2

  where
    ivs = MIP.integerVariables mip
    nivs = MIP.variables mip `Set.difference` ivs

    asInteger :: Rational -> Integer
    asInteger r
      | denominator r /= 1 = error (show r ++ " is not integer")
      | otherwise = numerator r
    
    nonAdjacentPairs :: [a] -> [(a,a)]
    nonAdjacentPairs (x1:x2:xs) = [(x1,x3) | x3 <- xs] ++ nonAdjacentPairs (x2:xs)
    nonAdjacentPairs _ = []

    asBin :: Integer.Expr -> SAT.Lit
    asBin (Integer.Expr [(1,[lit])]) = lit
    asBin _ = error "asBin: failure"

-- ------------------------------------------------------------------------

writeSOLFile :: Options -> SAT.Model -> Maybe Integer -> Int -> IO ()
writeSOLFile opt m obj nbvar = do
  case optWriteFile opt of
    Nothing -> return ()
    Just fname -> do
      let m2 = Map.fromList [("x" ++ show x, if b then 1 else 0) | (x,b) <- assocs m, x <= nbvar]
      writeFile fname (GurobiSol.render (Map.map fromInteger m2) (fmap fromInteger obj))


#if !MIN_VERSION_base(4,6,0)

modifyIORef' :: IORef a -> (a -> a) -> IO ()
modifyIORef' ref f = do
  x <- readIORef ref
  writeIORef ref $! f x

#endif
