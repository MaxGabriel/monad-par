{-# LANGUAGE BangPatterns, CPP #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing -fwarn-unused-imports #-}
-- -Wall 

-- A module for stream processing built on top of Control.Monad.Par

-- (In the future may want to look into the stream interface used by
--  the stream fusion framework.)

module Control.Monad.Par.Stream 
 ( 
   streamMap, streamScan, streamFold
 , countupWin, generate
 , runParList, toListSpin
 , measureRate, measureRateList
 , browseStream
 , Stream, Window, WStream

 -- TEMP:
 , one_second, commaint
 )
where
import Control.Monad
import Control.Monad.Par as P
import Control.Monad.Par.IList
import Control.DeepSeq

--import qualified Data.Array.Unboxed as U
import Data.Array.Unboxed as U
import Data.Array.CArray as C
import Data.Int
import Data.Word
import Data.List (intersperse)
import Data.List.Split (chunk)

import Foreign.Storable

import System.CPUTime
import System.CPUTime.Rdtsc
import GHC.Conc as Conc
import System.IO
import GHC.IO (unsafePerformIO, unsafeDupablePerformIO, unsafeInterleaveIO)
import Debug.Trace


debugflag = True

--------------------------------------------------------------------------------
-- Types

type Stream a = IVar (IList a)

-- A windowed stream passes chunks of stream elements.
type WStream a = Stream (Window a)

#define CARRAY
#ifdef CARRAY
type Window a = CArray Int a
#else
type Window a = U.UArray Int a
#endif


--------------------------------------------------------------------------------
-- Stream Operators

-- | This version applies a function to every element in a stream,
--   exposing data parallelism and pipeline parallelism.
streamMapDP :: NFData b => (a -> b) -> Stream a -> Par (Stream b)
streamMapDP fn instrm = 
    do outstrm <- new
       fork$ loop instrm outstrm
       return outstrm
 where
  loop instrm outstrm = 
   do 
      ilst <- get instrm
      case ilst of 
	Null -> put outstrm Null -- End of stream.
	Cons h t -> 
	  do newtl <- new
	     h' <- pval (fn h)	     

-- WARNING: This only makes sense with continuation-stealing..  With child stealing this will go crazy.
	     fork$ loop t newtl
	     h'' <- get h'
	     put outstrm (Cons h'' newtl)
	     

-- This version exposes pipeline parallelism but no data parallelism.
-- It shouldn't be necessary if fork is sufficiently efficient and if
-- work stealing is done right.
streamMap :: NFData b => (a -> b) -> Stream a -> Par (Stream b)
streamMap fn instrm = 
    do outstrm <- new
       fork$ loop instrm outstrm
       return outstrm
 where
  loop instrm outstrm = 
   do 
      ilst <- get instrm
      case ilst of 
	Null -> put outstrm Null -- End of stream.
	Cons h t -> 
	  do newtl <- new
	     put outstrm (Cons (fn h) newtl)
	     loop t newtl


-- | Applies a stateful kernel to the stream.  Output stream elements match input one-to-one.
streamScan :: (NFData b, NFData c) => 
	      (a -> b -> (a,c)) -> a -> Stream b -> Par (Stream c)
streamScan fn initstate instrm = 
    do outstrm <- new
       fork$ loop initstate instrm outstrm
       return outstrm
 where
  loop state instrm outstrm = 
   do 
      ilst <- get instrm
      case ilst of 
	Null -> put outstrm Null -- End of stream.
	Cons h t -> 
	  do newtl <- new
	     let (newstate, outp) = fn state h
	     put outstrm (Cons outp newtl)
	     loop newstate t newtl

-- TODO: streamMapM -- monadic version.  Define the non-monadic one in
-- terms of it and watch for performance regression.


-- TODO: More flexible version that passes an "emit" function to the
-- kernel so that it may produce zero output elements or more than one.
-- This also enables nested parallelism within the kernel.
-- 
-- streamKernel :: ((c -> Par ()) -> a -> b -> Par ()) -> a -> Stream b -> Par (Stream c)
--
-- ALSO: Can have a "concat" operator for streams of lists where
-- streamScan . concat rewrites to streamKernel perhaps...



-- | Reduce a stream to a single value.  This function will not return
--   until it reaches the end-of-stream.
streamFold :: (a -> b -> a) -> a -> Stream b -> Par a
streamFold fn acc instrm = 
   do ilst <- get instrm
      case ilst of 
	Null     -> return acc 
	Cons h t -> streamFold fn (fn acc h) t 

-- | Generate a stream of the given length by applying the function to each index (starting at zero).
-- 
-- WARNING, this source calls yield, letting other par computations
-- run, but there is no backpressure.  Thus if the source runs at a
-- higher rate than its consumer, buffered stream elements accumulate.
generate :: NFData a => Int -> (Int -> a) -> Par (Stream a)
-- NOTE: I don't currently know of a good way to do backpressure
-- directly in this system... but here are some other options: 
--
--   (1) we can use timers and look at maximum sustained rate.  

--   (2) Also, we can use coarse grained global barriers.  That is, we
--       can produce some number of output elements, wait until quiescence
--       of all Par computations, and then produce more.

--   (3) We can register computations that should only execute when a
--       worker goes idle.  This is a simple form of priority scheduling.
generate size fn = 
   do outstrm <- new
      fork$ loop (0::Int) outstrm
      return outstrm
 where 
  loop n strm | n == size = 
	  do when debugflag (print_$ " [generate] Done.  Produced "++ show size++" elements.\n")
	     put strm Null
             return ()
  loop n strm = 
    do 
       newtl <- new
       put strm (Cons (fn n) newtl)
       P.yield  -- This is necessary to avoid starving others when there
		-- aren't enough worker threads to go around.
       loop (n+1) newtl


-- | Create a [windowed] stream of consecutive integers.  Generates at
--   least the target number of elements windowed into segments of a
--   specified size.
countupWin :: (Storable a, NFData a, Num a) => 
              Int -> Int -> Par (WStream a)
countupWin bufsize target = 
   generate num fn
 where 
  num = case r of 0 -> q
		  _ -> q+1
  (q,r) = quotRem target bufsize
  fn n = 
   let start = n * bufsize in
   array (start,start + bufsize-1)
         [(i, fromIntegral (n + fromIntegral i)) 
	  | i <- [start .. start + bufsize-1]]



measureRate :: Stream a -> IO ()
measureRate strm = 
  do lazyls <- toListSpin strm
     measureRateList lazyls

measureRateList :: [a] -> IO ()
measureRateList lazyls = 
  do 
     t0 <- getTime
     print_$ " [measureRate] Counting stream rate starting at time: "++ show t0
     loop t0 t0 (0::Int64) (0::Int64) lazyls
     
 where 
  loop _     _    _     n [] = 
    do print_$ " [measureRate] Hit end of stream after "++show n++" elements."
       return ()

  loop start time lastN n (h:t) = 
       do 
	  time2 <- getTime
	  if time2 - time > one_second then do
	    (print_$ " [measureRate] current rate: "++show (n+1-lastN) ++ 
	             "  Total elems&time "++ commaint (n+1)++ "  " ++commaint (time2-start))
--               print_ (show (n+1))
	    loop start time2 (n+1) (n+1) t
	   else do
	    loop start time  lastN (n+1) t


-- | Use the keyboard to interactively browse through stream elements.
browseStream :: Show a => Stream a -> IO ()
browseStream strm = 
  do putStrLn$ "[browseStream] Beginning interactive stream browser, press enter for more elements:"
     ls <- toListSpin strm
     loop 0 ls
 where 
  loop n ls = 
   do putStr$ show n ++ "# "
      hFlush stdout
      c <- getChar      
      if c == '\EOT' -- User presses ctrl D to exit.
       then putStrLn$ "[browseStream] Ctrl-D pressed, exiting."
       else case ls of 
             []    -> putStrLn$ "[browseStream] Reached end of stream after "++show n++" elements."
             (h:t) -> do print h
		         loop (n+1) t


--------------------------------------------------------------------------------
-- Conversion:

-- Convert a stream to a lazy list.  Spin wait (with yield) until stream elements are available.
toListSpin :: Stream a -> IO [a]
toListSpin strm = 
   do x <- pollIVar strm
      case x of
        Nothing  -> do Conc.yield       -- run other GHC threads
                       toListSpin strm  -- spin wait
	Just (ils) -> 
	    case ils of 
	      Null     -> return []
	      Cons h t -> return (h : unsafePerformIO (unsafeInterleaveIO (toListSpin t)))


-- TODO: If it is unavailable we should help run the computation and then try again.
-- This version will do runParAsync itself:

-- Run a Par computation to produce a stream.  Convert that stream to a lazy list.
runParList :: Par (Stream a) -> [a]
runParList = 
  undefined
-- runForList parcomp = loop (runParAsync parcomp) 
--  where 
--   loop strm = 
--    do x <- pollIVar strm
--       case x of
--         Nothing  -> 
-- 	    -- For now we just spin:
-- 	    do yield -- run other GHC threads
-- 	       loop strm
-- 	Just (ils) -> 
-- 	    case ils of 
-- 	      Null     -> return []
-- 	      Cons h t -> return (h : unsafePerformIO (unsafeInterleaveIO (loop t)))




--------------------------------------------------------------------------------
-- Helpers and Scrap:

print_ msg = trace msg $ return ()

_unsafe_io :: IO a -> Par a
_unsafe_io io =  let x = unsafePerformIO io in
		 x `seq` return x

_unsafe_dupable :: IO a -> Par a
_unsafe_dupable io = 
  let x = unsafeDupablePerformIO io in 
  x `seq` return x

-- This version simply busy-waits to stay on the same core:
measure_freq2 :: IO Word64
measure_freq2 = do 
--  let second = 1000 * 1000 * 1000 * 1000 -- picoseconds are annoying
  let tenth = 100 * 1000 * 1000 * 1000 -- picoseconds are annoying      
      coef = 10
  t1 <- rdtsc 
  start <- getCPUTime
  let loop !n !last = 
       do t2 <- rdtsc 
	  when (t2 < last) $
	       putStrLn$ "WARNING, measure_freq2: COUNTERS WRAPPED "++ show (last,t2) 
	  cput <- getCPUTime		
--	  if (cput - start < second) 
	  if (cput - start < tenth)
	   then loop (n+1) t2
	   else return (n,t2)
  (n,t2) <- loop 0 t1
  putStrLn$ "  Approx getCPUTime calls per second: "++ commaint (coef * n)
  when (t2 < t1) $ 
    putStrLn$ "WARNING: rdtsc not monotonically increasing, first "++show t1++" then "++show t2++" on the same OS thread"

  return$ coef * fromIntegral (t2 - t1)

commaint :: Integral a => a -> String
commaint n = 
   reverse $
   concat $
   intersperse "," $ 
   chunk 3 $ 
   reverse (show n)

-- Having trouble with this:
-- getTime = getCPUTime
-- one_second = 1000000000000 -- picoseconds
getTime = rdtsc
one_second = unsafePerformIO$ measure_freq2


instance NFData (U.UArray a b) where 
  rnf !arr = ()

instance NFData (C.CArray a b) where 
  rnf !arr = ()