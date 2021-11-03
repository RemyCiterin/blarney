import Blarney
import Blarney.Stmt
import System.Environment

-- Top-level module
top :: Module ()
top = do
  -- RAM
  ram :: RAMBE 10 4 <- makeRAMBE

  -- Counter
  i :: Reg (Bit 10) <- makeReg 0

  -- Simple test sequence
  runStmt do
    while (i.val .<. 1000) do
      action do
        ram.storeBE i.val 1 (zeroExtend i.val)
        i <== i.val + 1
    action do
      i <== 0
    while (i.val .<. 1000) do
      action do
        ram.loadBE i.val
      action do
        display "ram[" i.val "] = " ram.outBE
        i <== i.val + 1
    action do
      finish

  return ()

-- Main function
main :: IO ()
main = do
  args <- getArgs
  if | "--simulate" `elem` args -> simulate top
     | otherwise -> writeVerilogTop top "RAMBE" "RAMBE-Verilog/"
