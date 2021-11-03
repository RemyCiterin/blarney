import Blarney
import Blarney.Queue
import Blarney.Stream
import Blarney.SourceSink
import System.Environment

-- Top-level module
top :: Module ()
top = do
  -- counter
  count :: Reg (Bit 32) <- makeReg 0
  -- queues
  q0 :: Queue (Bit 32) <- makeSizedQueue 3
  q1 :: Queue (Bit 32) <- makeSizedQueue 3
  q2 :: Queue (Bit 32) <- makeSizedQueue 3
  -- Sink/Source handles on the queue
  let (q0snk, q0src) = (toSink q0, toSource q0)
  -- queue as StreamProcessor from Queue itself
  let sp1 = toSP q1
  -- queue as StreamProcessor from (Sink, Source) pair
  let sp2 = toSP (toSink q2, toSource q2)

  -- example composition of stream processors
  s1 <- sp1 (toStream q0src) -- turn q0's source into a sink, an pass it to
                             -- q1's stream processor, and bind the output
                             -- stream to s1
  s2 <- sp2 s1               -- pass s1 to the q2's stream processor and bind
                             -- the output stream to s2

  -- feed chain of queues
  always do
    -- chain queues
    when (canPut q0snk) do q0snk.put count.val -- put count in q0's sink
    let q2src = toSource s2 -- example use of toSource
    -- Consume from q2
    when (q2src.canPeek .&&. count.val .>. 50) do
      q2src.consume
      display "Got " q2src.peek
      when (q2src.peek .>. 100) finish
    count <== count.val + 1

-- Main function
main :: IO ()
main = do
  args <- getArgs
  if | "--simulate" `elem` args -> simulate top
     | otherwise -> do
       writeVerilogTop top "SourceSink" "SourceSink-Verilog/"
