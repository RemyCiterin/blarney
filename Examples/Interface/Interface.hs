import Blarney
import Blarney.Queue
import Blarney.Stream
import System.Environment

-- Single-element FIFO

-- Module that increments each element in a stream
inc :: Stream (Bit 8) -> Module (Stream (Bit 8))
inc xs = do
  -- Output buffer
  buffer <- makeQueue

  always do
    -- Incrementer
    when (xs.canPeek .&&. buffer.notFull) do
      xs.consume
      buffer.enq (xs.peek + 1)

  -- Convert buffer to a stream
  return (toStream buffer)

-- This function creates an instance of a Verilog module called "inc"
makeIncS :: Stream (Bit 8) -> Module (Stream (Bit 8))
makeIncS = makeInstance "inc"

top :: Module ()
top = do
  -- Counter
  count :: Reg (Bit 8) <- makeReg 0

  -- Input buffer
  buffer <- makeQueue

  -- Create an instance of inc
  out <- makeIncS (toStream buffer)

  always do
    -- Fill input
    when buffer.notFull do
      buffer.enq count.val
      count <== count.val + 1

    -- Consume
    when out.canPeek do
      out.consume
      display "Got " out.peek
      when (out.peek .==. 100) finish

-- Main function
main :: IO ()
main = do
  args <- getArgs
  if | "--simulate" `elem` args -> simulate top
     | otherwise -> do writeVerilogModule inc "inc" "Interface-Verilog/"
                       writeVerilogTop top "Interface" "Interface-Verilog/"
