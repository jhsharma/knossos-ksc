module Main where

import Data.List (intercalate)


import Lang
import Prim
import AD
import ANF
import Opt
import CSE
import Parse
import Cgen (runM, cgenDef, cgenDefs)
import KMonad

ex1 :: Def
-- f x = let y = x*x in x + y
ex1 = Def (Fun (SFun "f1")) [sx] $
      Let sy (pMul (Var sx) (Var sx)) $
      pAdd (Var sx) (Var sy)

-- f' x dx = dx + 2*x*dx
-- f` x dr =

ex2 :: Def
-- g x = let y = x*x in
--       let z = x + y
--       in y*z
ex2 = Def (Fun (SFun "f2")) [sx] $
      Let sy (pMul (Var sx) (Var sx)) $
      Let sz (pAdd (Var sx) (Var sy))  $
      pMul (Var sy) (Var sz)

ex2a :: Def
-- f2a x = let zt = let y1 = x*x in (y1, x + y1)
--         let y2 = fst zt
--         let z = snd zt
--         in y2 * z
ex2a = Def (Fun (SFun "f2a")) [sx] $
      Let szt (Let sy1 (pMul (Var sx) (Var sx)) $
               Tuple [Var sy1, pAdd (Var sx) (Var sy1)]) $
      Let sy2 (pFst (Var szt)) $
      Let sz (pSnd (Var szt)) $
      pMul (Var sy2) (Var sz)

ex3 :: Def
-- h (x,y) = let z = x + y
--           in y*z
ex3 = Def (Fun (SFun "f3")) [sp] $
      Let sx (pFst (Var sp))    $
      Let sy (pSnd (Var sp))    $
      Let sz (pAdd (Var sx) (Var sy))  $
      pMul (Var sy) (Var sz)

ex4 :: Def
-- h x y = let z = x + y
--         in y*z
ex4 = Def (Fun (SFun "f4")) [sx,sy] $
      Let sz (pAdd (Var sx) (Var sy))  $
      pMul (Var sy) (Var sz)

ex5 :: Def
-- f5 x y = let p = 7 * x
--          let r = 1 / y
--          let q = p *x * 5
--          let v = (2*p*q) + (3*r)
--          in v
ex5 = Def (Fun (SFun "f5")) [sx,sy] $
      Let sp (pMul (kInt 7) (Var sx)) $
      Let sr (pDiv (kInt 1) (Var sy)) $
      Let sq (pMul (Var sp) (pMul (Var sx) (kInt 5))) $
      Let sv (pAdd (pMul (kInt 2) (pMul (Var sp) (Var sq)))
                   (pMul (kInt 3) (Var sr))) $
      Var sv

ex6 :: Def
-- f6 x y = sum (x * y)
ex6 = Def (Fun (SFun "dot")) [sx, sy] $
      pSum (pMul (Var sx) (Var sy))

ex7 :: Def
-- f7 x y = sum (build (size x) (\i -> x[i] * y[i]))
ex7 = Def (Fun (SFun "dot2")) [sx, sy] $
      assertEqual (pSize (Var sx)) (pSize (Var sy)) $
      pSum (pBuild (pSize (Var sx))
                   (Lam si (pMul (pIndex (Var si) (Var sx))
                                 (pIndex (Var si) (Var sy)))))

ex8 :: Def
-- f8 x = sum (build (size x) (\i -> -x[i]))
ex8 = Def (Fun (SFun "f8")) [svx] $
      pSum (pBuild (pSize (Var svx))
                   (Lam si (pNeg (pIndex (Var si) (Var sx)))))


si, sp, sq, sr, sv, sx, sy, sz :: Var
si = TVar TypeInteger (Simple "i")
sp = TVar TypeFloat   (Simple "p")
sq = TVar TypeFloat   (Simple "q")
sr = TVar TypeFloat   (Simple "r")
sv = TVar TypeFloat   (Simple "v")
sx = TVar TypeFloat   (Simple "x")
svx = TVar (TypeVec TypeFloat)   (Simple "vx")
sy = TVar TypeFloat   (Simple "y")
sy1 = TVar TypeFloat  (Simple "y1")
sy2 = TVar TypeFloat  (Simple "y2")
sz = TVar TypeFloat   (Simple "z")
szt = TVar TypeFloat  (Simple "zt")



-------------------------------------
-- C++ generation
-------------------------------------

cppF :: String -> IO ()
-- String is the file name
cppF file
  = do  
        cts <- readFile file

        let lines = [ 
                      "#include <stdio.h>"
                    , "#include \"knossos.h\""
                    ]

        let lls = case runParser pDefs cts of
                    Left err   -> error ("Failed parse: " ++ show err)
                    Right defs -> cgenDefs defs
        
        let tail = [ 
                      "int main() {"
                    , "  ks_main(tuple<>{});"
                    , "}"
                    ]
        writeFile "tmp1.cpp" (intercalate "\n" (lines ++ lls ++ tail))

cppV file = do
      cppF file
      readFile "tmp1.cpp" >>= putStrLn;
      putStrLn "^^^^^^---- Written to tmp1.cpp ----^^^^^^^^^"

cppExample :: IO ()
cppExample = do
    mapM_
      putStrLn
      [ "#include <stdio.h>"
      , "#include \"knossos.h\""
      , r Main.ex1
      -- , r Main.ex2
      -- , r Main.ex2a
      -- , r Main.ex3
      -- , r Main.ex4
      -- , r Main.ex5
      -- , r Main.ex7
      -- , r Main.ex8
      , "int main(void) { "
      ++ printFloat "f1(2)"
      ++ printFloat "f2(2)"
      ++ printFloat "f2a(2)"
      ++ printFloat "f3((struct tuple2) { .field1_2 = 2, .field2_2 = 3 })"
      ++ printFloat "f4(2, 3)"
      ++ printFloat "f5(2, 3)"
      ++ printFloat "dot2(v1, v2)"
      ++ printFloat "f8(v1)"
      ++ "}"
      ]
    where r = cgenDef
  
printFloat :: String -> String
printFloat s = unlines
  ["printf(\"%s\\n\", \"" ++ s ++ "\");", "printf(\"%f\\n\\n\", " ++ s ++ ");"]


-------------------------------------
--  The demo driver
-------------------------------------

demoF :: String -> IO ()
-- String is the file name
demoF file
  = do { cts <- readFile file
       ; case runParser pDefs cts of
            Left err   -> putStrLn ("Failed parse: " ++ show err)
            Right defs -> runKM (demoN defs) }

demo :: Def -> IO ()
demo d = runKM (demoN [d])

demoN :: [Def] -> KM ()
demoN def
  = do { banner "Original definition"
       ; displayN def

       ; banner "Anf-ised original definition"
       ; anf_def <- anfDefs def
       ; displayN anf_def

       ; banner "The full Jacobian (unoptimised)"
       ; let grad_def = gradDefs anf_def
       ; displayN grad_def

       ; banner "The full Jacobian (optimised)"
       ; let opt_grad_def = optDefs grad_def
       ; displayN opt_grad_def

       ; banner "Forward derivative (unoptimised)"
       ; let der_fwd = map applyD opt_grad_def
       ; displayN der_fwd

       ; banner "Forward-mode derivative (optimised)"
       ; let opt_der_fwd = optDefs der_fwd
       ; displayN opt_der_fwd

       ; banner "Forward-mode derivative (CSE'd)"
       ; cse_fwd <- cseDefs opt_der_fwd
       ; displayN cse_fwd

       ; banner "Transposed Jacobian"
       ; let trans_grad_def = map transposeD opt_grad_def
       ; displayN trans_grad_def

       ; banner "Optimised transposed Jacobian"
       ; let opt_trans_grad_def = optDefs trans_grad_def
       ; displayN opt_trans_grad_def

       ; banner "Reverse-mode derivative (unoptimised)"
       ; let der_rev = map applyD opt_trans_grad_def
       ; displayN der_rev

       ; banner "Reverse-mode derivative (optimised)"
       ; let opt_der_rev = optDefs der_rev
       ; displayN opt_der_rev

       ; cse_rev <- cseDefs opt_der_rev
       ; banner "Reverse-mode derivative (CSE'd)"
       ; displayN cse_rev
       }


main :: IO ()
main = return ()  -- To keep GHC quiet
