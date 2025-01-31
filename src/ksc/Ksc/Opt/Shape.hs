-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT license.

module Ksc.Opt.Shape where

import Ksc.Lang
import Ksc.Prim

-- See Note [Compressed shape types]

optShape :: TExpr -> TExpr

optShape (Dummy ty)
  | Just s_ty <- shapeType ty
  = Dummy s_ty
optShape (Assert e1 e2) =  Assert e1 (pShape e2)
optShape (If b t e)     =  If b (pShape t) (pShape e)
optShape (Let v e1 e2)  =  Let v e1 (pShape e2)
optShape (Call (TFun _ (Fun JustFun (PrimFunT p))) arg)
  | Just optimised <- optShapePrim p arg
  = optimised
optShape (Call (TFun ty (Fun ds f@(BaseFunId BaseUserFunName{} _))) e)
  | Just s_ty <- shapeType ty
  = Call (TFun s_ty (Fun (ShapeFun ds) f)) e
optShape (Lam{}) = error "Unexpected Lam in call of optShape: shape of function type not supported"
optShape e
  | Just s <- shape1 e
  = s
  | otherwise
  = pprPanic "Didn't have a shape" (ppr e)

optShapePrim :: PrimFun -> TExpr -> Maybe TExpr
optShapePrim P_sumbuild (Tuple [sz, Lam i e2]) = Just $ mkLet i (mkZero sz) (pShape e2)
optShapePrim P_ts_add (Tuple [lhs, _]) = Just $ pShape lhs
optShapePrim P_ts_scale (Tuple [_, v]) = Just $ pShape v
optShapePrim P_ts_neg v = Just $ pShape v
optShapePrim P_delta (Tuple [_, _, v]) = Just $ pShape v
optShapePrim P_trace v = Just $ pShape v
optShapePrim P_copydown v = Just $ pShape v
optShapePrim _ _ = Nothing
