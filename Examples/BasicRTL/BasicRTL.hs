import Blarney
import System.Environment

top :: Module ()
top = do
  -- Create a register
  cycleCount :: Reg (Bit 4) <- makeReg 0
  -- Check for DEBUG plusarg
  let isDebug = testPlusArgs "DEBUG"

  always do
    -- Increment on every cycle
    cycleCount <== cycleCount.val + 1

    -- Display value an every cycle
    display "cycleCount = " cycleCount.val

    -- Terminate simulation when count reaches 10
    when (cycleCount.val .==. 10) do
      display "Finished"
      finish

    -- Display "DEBUG" when +DEBUG is passed as a plusargs
    when isDebug do
      display "running with +DEBUG"

main :: IO ()
main = do
  args <- getArgs
  if | "--simulate" `elem` args -> simulate top
     | otherwise -> writeVerilogTop top "BasicRTL" "BasicRTL-Verilog/"
