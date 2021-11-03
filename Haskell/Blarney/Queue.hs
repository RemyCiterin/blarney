{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE BlockArguments        #-}
{-# LANGUAGE RebindableSyntax      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-|
Module      : Blarney.Queue
Description : Library of various queue implementations
Copyright   : (c) Matthew Naylor, 2019
              (c) Alexandre Joannou, 2019-2021
License     : MIT
Maintainer  : mattfn@gmail.com
Stability   : experimental
-}
module Blarney.Queue where

-- Blarney imports
import Blarney
import Blarney.Stream
import Blarney.Option
import Blarney.SourceSink

-- Standard imports
import Data.Proxy

-- | Queue interface
data Queue a = Queue { notEmpty :: Bit 1
                     , notFull  :: Bit 1
                     , enq      :: a -> Action ()
                     , deq      :: Action ()
                     , canDeq   :: Bit 1
                     , first    :: a
                     } deriving (Generic, Interface)

-- | ToSource instance for Queue
instance ToSource (Queue t) t where
  toSource q = Source { canPeek = q.canDeq
                      , peek    = q.first
                      , consume = q.deq
                      }

-- | ToSink instance for Queue
instance ToSink (Queue t) t where
  toSink q = Sink { canPut = q.notFull
                  , put    = q.enq
                  }

-- | ToSP instance for Queue
instance ToSP (Queue a) a a where
  toSP q = \s -> let cond = s.canPeek .&. q.notFull in
                 do always do when cond do (q.enq) (s.peek)
                                           s.consume
                    return $ Source { consume = q.deq
                                    , canPeek = q.canDeq
                                    , peek    = q.first
                                    }
{-|
A full-throughput 2-element queue implemented using 2 registers:

  * No combinatorial paths between sides.

  * There's a mux on the enqueue path.
-}
makeQueue :: Bits a => Module (Queue a)
makeQueue = do
  -- Elements of the queue, stored in registers
  elem0 :: Reg a <- makeReg dontCare
  elem1 :: Reg a <- makeReg dontCare

  -- Which elements are valid (i.e. contain a queue value)?
  valid0 :: Reg (Bit 1) <- makeReg 0
  valid1 :: Reg (Bit 1) <- makeReg 0

  -- Wires
  doEnq :: Wire a <- makeWire dontCare
  doDeq :: Wire (Bit 1) <- makeWire 0
  update1 :: Wire (Bit 1) <- makeWire 0

  always do
    if inv valid0.val .|. doDeq.val
      then do
        -- Update element 0
        valid0 <== valid1.val .|. doEnq.active
        elem0  <== valid1.val ? (elem1.val, doEnq.val)
        when (valid1.val) do
          -- Update element 1
          valid1 <== doEnq.active
          update1 <== 1
      else do
        when (doEnq.active) do
          -- Update element 1
          valid1 <== 1
          update1 <== 1

    when update1.val (elem1 <== doEnq.val)

  return
    Queue {
      notEmpty = valid0.val
    , notFull  = inv valid1.val
    , enq      = \a -> doEnq <== a
    , deq      = doDeq <== 1
    , canDeq   = valid0.val
    , first    = elem0.val
    }

{-|
A full-throughput N-element queue implemented using 2 registers and a RAM:

  * No combinatorial paths between sides.

  * There's a mux on the enqueue path.
-}
makeSizedQueue :: Bits a => Int -> Module (Queue a)
makeSizedQueue logSize =
  makeSizedQueueConfig
    SizedQueueConfig {
      sizedQueueLogSize = logSize
    , sizedQueueBuffer = makeQueue
    }

-- | Config options for a sized queue
data SizedQueueConfig a =
  SizedQueueConfig {
    sizedQueueLogSize :: Int
    -- ^ Log of capacity of queue
  , sizedQueueBuffer :: Module (Queue a)
    -- ^ Type of queue to use as buffer on output of RAM
  }

-- | Sized queue with config options
makeSizedQueueConfig :: Bits a => SizedQueueConfig a -> Module (Queue a)
makeSizedQueueConfig config = do
  -- Big queue
  big :: Queue a <- makeSizedQueueCore (config.sizedQueueLogSize)

  -- Small queue, buffering the output of the big queue
  small :: Queue a <- config.sizedQueueBuffer

  always do
    -- Connect big queue to small queue
    when (small.notFull .&. big.canDeq) do
      deq big
      enq small (big.first)

  return
    Queue {
      notEmpty = small.notEmpty .&. big.notEmpty
    , notFull  = big.notFull
    , enq      = big.enq
    , deq      = deq small
    , canDeq   = small.canDeq
    , first    = small.first
    }

-- |This one has no output buffer (low latency, but not great for Fmax)
makeSizedQueueCore :: Bits a => Int -> Module (Queue a)
makeSizedQueueCore logSize =
  -- Lift size n to type-level address-width
  liftNat logSize $ \(_ :: Proxy aw) -> do

    -- A dual-port RAM, wide enough to hold entire queue
    ram :: RAM (Bit aw) a <- makeDualRAMForward

    -- Queue front and back pointers
    front :: Reg (Bit aw) <- makeReg 0
    back :: Reg (Bit aw) <- makeReg 0

    -- Full/empty status
    full :: Reg (Bit 1)  <- makeReg 0
    empty :: Reg (Bit 1)  <- makeReg 1

    -- Wires
    doEnq :: Wire a <- makeWire dontCare
    doDeq :: Wire (Bit 1) <- makeWire 0

    always do
      -- Read from new front pointer and update
      let newFront = doDeq.val ? (front.val + 1, front.val)
      ram.load newFront
      front <== newFront

      if doEnq.active
        then do
          let newBack = back.val + 1
          back <== newBack
          ram.store back.val doEnq.val
          when (inv doDeq.val) do
            empty <== 0
            when (newBack .==. front.val) (full <== 1)
        else do
          when doDeq.val do
            full <== 0
            when (newFront .==. back.val) (empty <== 1)

    return
      Queue {
        notEmpty = inv empty.val
      , notFull  = inv full.val
      , enq      = \a -> doEnq <== a
      , deq      = doDeq <== 1
      , canDeq   = inv empty.val
      , first    = ram.out
      }

{-|
There are modes of operation for the shift queue (below):

  1. Optimise throughput: full throughput, but there's a
     combinatorial path between notFull and deq

  2. Optimise Fmax: no combinatorial paths between sides,
     but max throughput = N/(N+1), where N is the queue capacity
-}
data ShiftQueueMode = OptFmax | OptThroughput deriving Eq

{-|
An N-element queue implemented using a shift register:

  * No muxes: input element goes straight to a register and output element
    comes straight from a register.

  * N-cycle latency between enqueuing an element and being able to dequeue
    it, where N is the queue capacity.

This version optimised for Fmax.
-}
makeShiftQueue :: Bits a => Int -> Module (Queue a)
makeShiftQueue n = do
  (q, _) <- makeShiftQueueCore OptFmax n
  return q

-- |This version is optimised for throughput
makePipelineQueue :: Bits a => Int -> Module (Queue a)
makePipelineQueue n = do
  (q, _) <- makeShiftQueueCore OptThroughput n
  return q

makeShiftQueueCore :: Bits a =>
     ShiftQueueMode
     -- ^ Optimise for throughput or Fmax?
  -> Int
     -- ^ Size of queue
  -> Module (Queue a, [Option a])
     -- ^ Return a standard queue interface, but also the contents to be viewed
makeShiftQueueCore mode n = do
  -- Elements of the queue, stored in registers
  elems :: [Reg a] <- replicateM n makeRegU

  -- Which elements are valid?
  valids :: [Reg (Bit 1)] <- replicateM n (makeReg 0)

  -- Wires
  doEnq :: Wire a <- makeWire dontCare
  doDeq :: Wire (Bit 1) <- makeWire 0

  -- Register enable line to each element
  let ens = tail $ scanl (.|.) doDeq.val [inv v.val | v <- valids]

  always do
    -- Update elements
    sequence_ [ when en (x <== y.val)
              | (en, x, y) <- zip3 ens elems (tail elems) ]

    -- Update valid bits
    sequence_ [ when en (x <== y.val)
              | (en, x, y) <- zip3 ens valids (tail valids) ]

    -- Don't insert new element
    when (inv doEnq.active .&. last ens) do
      last valids <== 0

    -- Insert new element
    when (doEnq.active) do
      last valids <== 1
      last elems <== doEnq.val

  return
    ( Queue {
        notEmpty = orList (map (.val) valids)
      , notFull  = inv (andList (map (.val) valids)) .|.
                     (if mode == OptFmax then 0 else doDeq.val)
      , enq      = \a -> doEnq <== a
      , deq      = doDeq <== 1
      , canDeq   = (head valids).val
      , first    = (head elems).val
      }
    , [Option v.val e.val | (v, e) <- zip valids elems] )

-- |Single element bypass queue
makeBypassQueue :: Bits a => Module (Queue a)
makeBypassQueue = do
  -- Data register
  dataReg <- makeReg dontCare
  dataRegFull <- makeReg false
  -- Data wire (by default emits the value of the data register)
  dataWire <- makeWire dataReg.val
  -- Dequeue trigger
  doDeq <- makeWire false

  always do
    if doDeq.val
      then dataRegFull <== false
      else do
        when (dataWire.active) do
          dataRegFull <== true
          dataReg <== dataWire.val

  -- Can dequeue when wire is being enqueued, or when data reg full
  let canDeqVal = dataWire.active .|. dataRegFull.val

  return
    Queue {
      notEmpty = canDeqVal
    , notFull  = inv dataRegFull.val
    , enq      = \a -> dataWire <== a
    , deq      = doDeq <== true
    , canDeq   = canDeqVal
    , first    = dataWire.val
    }

-- | Insert a queue in front of a sink
makeSinkBuffer :: Bits a => Module (Queue a) -> Sink a -> Module (Sink a)
makeSinkBuffer makeQueue sink = do
  q <- makeQueue

  always do
    when (q.notEmpty .&&. sink.canPut) do
      q.deq
      put sink (q.first)

  return
    Sink {
      canPut = q.notFull
    , put = enq q
    }
