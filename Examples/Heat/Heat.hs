import Mesh
import Blarney
import Data.List
import System.Environment

-- Heat diffusion on a 2D mesh

-- Temperature type
type Temp = Bit 32

-- Update cell using values of neighbours
step :: Reg Temp -> [Temp] -> Action ()
step me neighbours =
  me <== sumList neighbours .>>. (2 :: Bit 2)

-- Top-level
top :: Integer -> Int -> Int -> Module ()
top t w h = do
  -- North and east borders (initialised hot)
  north <- replicateM w (makeReg 0xff0000)
  east  <- replicateM (h-2) (makeReg 0xff0000)
  -- South and west borders (initialised cold)
  south <- replicateM w (makeReg 0x2a0000)
  west  <- replicateM (h-2) (makeReg 0x2a0000)
  -- Remaining cells
  cells <- replicateM (h-2) (replicateM (w-2) (makeReg 0))
  -- Count time steps
  timer :: Reg (Bit 32) <- makeReg 0
  -- Overall grid
  let grid = [north]
          ++ transpose ([east] ++ transpose cells ++ [west])
          ++ [south]
  always do
    -- Mesh
    mesh step grid
    -- Increment time
    timer <== timer.val + 1
    -- Termination
    when (timer.val .==. fromInteger t) do
      forM_ (zip [0..] grid) $ \(i, row) ->
        forM_ (zip [0..] row) $ \(j, cell) -> do
          let out = cell.val .>>. (16 :: Bit 5)
          when (out .!=. 0) do
            display (show i) "," (show j) ":" out
      finish

-- Main function
main :: IO ()
main = do
  args <- getArgs
  if | "--simulate" `elem` args -> simulate (top 10 128 128)
     | otherwise -> writeVerilogTop (top 10 128 128) "Heat" "Heat-Verilog/"
