import Blarney
import Blarney.Recipe
import System.Environment

fact :: Module ()
fact = do
  -- State
  n   :: Reg (Bit 32) <- makeReg 0
  acc :: Reg (Bit 32) <- makeReg 1

  -- Compute factorial of 10
  let recipe =
        Seq [
          Action do
            n <== 10
        , While (n.val .>. 0) (
            Action do
              n <== n.val - 1
              acc <== acc.val * n.val
          )
        , Action do
            display "fact(10) = " acc.val
            finish
        ]

  runRecipe recipe

main :: IO ()
main = do
  args <- getArgs
  if | "--simulate" `elem` args -> simulate fact
     | otherwise -> writeVerilogTop fact "Factorial" "Factorial-Verilog/"
