-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT license.
{-# LANGUAGE LambdaCase, FlexibleInstances, PatternSynonyms  #-}

module Cgen where

import           GHC.Stack
import           Prelude                 hiding ( lines
                                                , tail
                                                )

import qualified Data.Map                      as Map
import           Data.List                      ( intercalate )
import           Data.Maybe                     ( mapMaybe )
import           Control.Monad                  ( when )
import qualified Control.Monad.State           as S
import qualified System.Directory
import qualified System.FilePath
import qualified System.Process
import           System.Exit                    ( ExitCode(ExitSuccess) )

import           Lang                    hiding ( (<>) )
import qualified OptLet

import Debug.Trace

data CType =  CType Type
            | CTuple [CType]
            | CFunction CType CType
            | TypeDef String CType
            | UseTypeDef String
            | LMZero Type Type
            | LMOne Type
            | LMScale Type
            | LMHCat [CType]
            | LMVCat [CType]
            | LMBuild CType
            | LMCompose CType CType
            | LMAdd [CType]
            | LMVariant [CType]
            deriving (Eq, Ord, Show)

isScalar :: CType -> Bool
isScalar = \case
  CType  t      -> Lang.isScalar t
  CTuple ts     -> all Cgen.isScalar ts
  CFunction _ _ -> False
  TypeDef   _ t -> Cgen.isScalar t
  UseTypeDef _  -> False
  LMZero _ _    -> False
  LMOne _       -> False
  LMScale  _    -> False
  LMHCat   _    -> False
  LMVCat   _    -> False
  LMBuild  _    -> False
  LMCompose _ _ -> False
  LMAdd     _   -> False
  LMVariant _   -> False

mkCType :: Type -> CType
mkCType (TypeTuple ts) = CTuple $ map mkCType ts
mkCType ty             = CType ty

stripTypeDef :: HasCallStack => CType -> CType
stripTypeDef (TypeDef _ t) = stripTypeDef t
stripTypeDef t             = t

stripCType :: CType -> Type
stripCType = \case
  CType  ty     -> ty
  CTuple tys    -> TypeTuple $ map stripCType tys
  TypeDef _ cty -> stripCType cty
  _             -> error "LM/Function type in stripCType"

cgenIsLM :: HasCallStack => CType -> Bool
cgenIsLM = \case
  CType  (TypeLM _ _) -> True
  CType  _            -> False
  CTuple ts           -> any cgenIsLM ts
  CFunction _ _       -> False
  TypeDef   _ ty      -> cgenIsLM ty
  UseTypeDef s        -> error ("Don't know; it's a UseTypeDef: " ++ s)
  _                   -> True

isUseTypeDef :: CType -> Bool
isUseTypeDef (UseTypeDef _) = True
isUseTypeDef _ = False

makeUnionType :: HasCallStack => CType -> CType -> CType
makeUnionType (CTuple ts) (CTuple us) =
  if ts == us
  then CTuple ts
  else
    CTuple $ zipWith makeUnionType ts us

makeUnionType ty1 ty2 =
  if ty1 == ty2
  then ty1
  else if isUseTypeDef ty1  -- Punt and hope it's fine for now...
  then ty2
  else if isUseTypeDef ty2
  then ty1
  else if cgenIsLM (trace ("***Making variant from \n" ++ show ty1 ++ "\n" ++ show ty2) ty1)
  then  -- trace ("***Making variant from \n" ++ show ty1 ++ "\n" ++ show ty2)
        LMVariant [ty1, ty2]
  else
    let sty1 = stripCType ty1
        sty2 = stripCType ty2
    in  if sty1 == sty2
          then mkCType sty1
          else error
            ("GENVAR[\n" ++ show ty1 ++ "\n" ++ show ty2 ++ "\n]")

-------------- String utils

spc :: String -> String -> String
spc x y = x ++ " " ++ y

indent :: [String] -> [String]
indent = map ("  " ++)

makeBlock :: [String] -> [String]
makeBlock [] = []
makeBlock [line] = [line]
makeBlock lines = [ "{" ] ++ indent lines ++ [ "}" ]

-------------- State for var generator

type M = S.State Int

runM :: M a -> a
runM = flip S.evalState 0

freshCVar :: M String
freshCVar = do
  s <- S.get
  S.put (s + 1)
  return ("c$" ++ show s)

-------------------- Cgen

data AllocatorUsage = DoesNotUseAllocator | UsesAllocator | UsesAndResetsAllocator

instance Semigroup AllocatorUsage where
  (<>) = combineUsage

instance Monoid AllocatorUsage where
  mempty = DoesNotUseAllocator

combineUsage :: AllocatorUsage -> AllocatorUsage -> AllocatorUsage
combineUsage UsesAllocator _ = UsesAllocator
combineUsage _ UsesAllocator = UsesAllocator
combineUsage DoesNotUseAllocator DoesNotUseAllocator = DoesNotUseAllocator
combineUsage _ _ = UsesAndResetsAllocator

-- CGenResult is (C declarations, C expression, CType)
-- e.g. (["double r; if (b) { r = 1; } else { r = 2; };"],
--       "r",
--       TypeDouble)
-- e.g. ([],         -- simple constant needs no pre-declaration
--       "1.0",      -- this is what we use at the occurrence
--       TypeDouble)
-- e.g. (["typedef LM::HCat<LM::VCat<LM::One, LM::Zero>,LM::Zero> v12_t;",
--        "v12_t v12 = v12_t::mk(a,b);"]
--       "v12",      -- this is what we use at the occurrence
--       LMHCat [LMVCat [LMOne, LMZero], LMZero])
data CGenResult = CG [String] String CType AllocatorUsage -- TODO: rename CG CGenResult

getDecl :: CGenResult -> [String]
getDecl (CG dc _ _ _) = dc

getExpr :: CGenResult -> String
getExpr (CG _ ex _ _) = ex

getType :: CGenResult -> CType
getType (CG _ _ ty _) = ty

getAllocatorUsage :: CGenResult -> AllocatorUsage
getAllocatorUsage (CG _ _ _ au) = au

type CSTKey = (Fun, Type)
type CST    = Map.Map CSTKey ()

cstMaybeLookupFun :: HasCallStack => CSTKey -> CST -> Maybe ()
cstMaybeLookupFun = Map.lookup

cComment :: String -> String
cComment s = "/* " ++ s ++ " */"

markAllocator :: String -> String -> String
markAllocator bumpmark allocVar = "ks::alloc_mark_t " ++ bumpmark ++ " = " ++ allocVar ++ "->mark();"

resetAllocator :: String -> String -> String
resetAllocator bumpmark allocVar = allocVar ++ "->reset(" ++ bumpmark ++ ");"

declareMark :: String -> String
declareMark bumpmark = "ks::alloc_mark_t " ++ bumpmark ++ ";"

moveMark :: String -> String -> String
moveMark bumpmark allocVar = bumpmark ++ " = " ++ allocVar ++ "->mark();"

allocatorParameterName :: String
allocatorParameterName = "$alloc"

cgenArgList :: TFun -> [String] -> String
cgenArgList tf cargs = intercalate ", " (allocatorIfUsed ++ cargs)
  where allocatorIfUsed = if funUsesAllocator tf
                          then [allocatorParameterName]
                          else []

cgenDefs :: [TDef] -> [String]
cgenDefs defs = concatMap cdecl $
                filter isUserDef defs
 where
  env = Map.fromList (mapMaybe (\(Def { def_fun = f
                                      , def_rhs = rhs
                                      , def_pat = arg
                                      }) ->
                                  case rhs of
                                    UserRhs _ -> Just ((f, typeof arg), ())
                                    _         -> Nothing) defs)

  cdecl def = cgenDefE env def ++ [ "" ]

{- Note [Unpack tuple arguments]

Defs of a tuple argument have their argument list unpacked,
that is, if f is a Def of type Tuple [S1, ..., SN] -> T
then the C++ function we generate for it will have N
arguments, not one tuple.

We choose N names for the argument variables and pack them into a
tuple before emitting the function body.  We ensure that the names
that we chose are not used in the function body by using substExpr.

A consequence of this translation is that we have to unpack tuples in
*calls* too.  When 'x' of type 'Tuple [S1, ..., SN]', 'Call f x' needs
to be rewritten to a C++ call like

    f(get<0>(x), ..., get<N-1>(x))

There is special case when x is a literal tuple.  In that case we take
the tuple components directly for the arguments of 'f'.  This seems to
be particularly important for avoiding a 5x slowdown.  See

    https://github.com/microsoft/knossos-ksc/pull/315

-}

ensureDon'tReuseParams :: [TVar] -> TExpr -> TExpr
ensureDon'tReuseParams = OptLet.substExpr . OptLet.mkEmptySubst

params_withPackedParamsPat :: Pat -> ([TVarX], TExpr -> TExpr)
params_withPackedParamsPat (TupPat vs)    = (vs, id)
params_withPackedParamsPat (VarPat param) = params_withPackedParams param

params_withPackedParams :: TVarX -> ([TVarX], TExpr -> TExpr)
params_withPackedParams param = case typeof param of
  -- See Note [Unpack tuple arguments]
  TypeTuple tys ->
    let params  = zipWith mkParam [1..] tys
        mkParam i ty = TVar ty (Simple name)
          where name = nameOfVar (tVarVar param) ++ "arg" ++ show i
        packParams = Let param (Tuple (map Var params))
    in (params, ensureDon'tReuseParams params . packParams)
  _             -> ([param], id)

mkCTypedVar :: TVar -> String
mkCTypedVar (TVar ty var) = cgenType (mkCType ty) `spc` cgenVar var

cgenDefE :: CST -> TDef -> [String]
cgenDefE env (Def { def_fun = f, def_pat = param
                  , def_rhs = UserRhs body }) =
  let cf                         = cgenUserFun (f, typeof param)
      (params, withPackedParams) = params_withPackedParamsPat param
      CG cbodydecl cbodyexpr cbodytype _callocusage =
        runM $ cgenExpr env (withPackedParams body)
      cbody       = cbodydecl ++ [ "return (" ++ cbodyexpr ++ ");" ]
      cvars       = map mkCTypedVar params
      cftypealias = "ty$" ++ cf
      cparams     = "ks::allocator * " ++ allocatorParameterName ++ concatMap (", " ++) cvars
  in (  [ "typedef " ++ cgenType cbodytype `spc` cftypealias ++ ";",
          cftypealias `spc` cf ++ "(" ++ cparams ++ ") {" ]
     ++ indent cbody
     ++ [ "}" ]
     )

cgenDefE _ def = pprPanic "cgenDefE" (ppr def)
  -- Should not happen because of the 'filter isUserDef' in cgenDefs

cgenExpr :: CST -> TExpr -> M CGenResult
cgenExpr = cgenExprR

cgenExprR :: HasCallStack => CST -> TExpr -> M CGenResult
cgenExprR env e = do
  cg <- cgenExprWithoutResettingAlloc env e
  cgenWrapWithMarkReset cg

cgenWrapWithMarkReset :: HasCallStack => CGenResult -> M CGenResult
cgenWrapWithMarkReset (CG decl expr ty UsesAllocator)
  | Cgen.isScalar ty = do
      bumpmark <- freshCVar
      return $ CG
        (  [ markAllocator bumpmark allocatorParameterName ]
        ++ decl
        ++ [ resetAllocator bumpmark allocatorParameterName ]
        )
        expr
        ty
        UsesAndResetsAllocator
cgenWrapWithMarkReset x = return x

cgenExprWithoutResettingAlloc :: HasCallStack => CST -> TExpr -> M CGenResult
cgenExprWithoutResettingAlloc env = \case
  Konst k -> return $ CG [] (cgenKonst k) (mkCType $ typeofKonst k) DoesNotUseAllocator
  Dummy ty ->
    let cty = mkCType ty in return $ CG [] (cgenType cty ++ "{}") cty DoesNotUseAllocator
  Var (TVar ty v)               -> return $ CG [] (cgenVar v) (mkCType ty) DoesNotUseAllocator

  -- Special case for build -- inline the loop
  Call (TFun (TypeVec ty) (Fun (PrimFun "build"))) (Tuple [sz, Lam (TVar vty var) body]) -> do
    CG szdecl szex _szty _szau <- cgenExprR env sz
    let varty = mkCType vty
    let varcty = cgenType varty
    CG bodydecl bodyex _bodyty _bodyau <- cgenExprR env body

    ret  <- freshCVar
    cvar <- freshCVar

    return $ CG
        (  [ cComment "build" ]
        ++ szdecl
        ++ [ "vec<" ++ cgenType (mkCType ty) ++ "> " ++ ret ++ "(" ++ allocatorParameterName ++ ", " ++ szex ++ ");",
             "for(" ++ varcty ++ " " ++ cvar ++ " = 0;"
                    ++ cvar ++ " < " ++ szex ++ ";"
                    ++ " ++" ++ cvar ++ ") {" ]
        ++ indent (  [ varcty ++ " " ++ cgenVar var ++ " = " ++ cvar ++ ";" ]
                  ++ bodydecl
                  ++ [ ret ++ "[" ++ cvar ++ "] = " ++ bodyex ++ ";" ]
                  )
        ++ [ "}" ]
        )
        ret
        (mkCType (TypeVec ty))
        UsesAllocator

  -- Special case for sumbuild -- inline the loop
  Call (TFun ty (Fun (PrimFun "sumbuild"))) (Tuple [sz, Lam (TVar vty var@(Simple _)) body]) -> do
    CG szdecl szex _szty _szau <- cgenExprR env sz
    let varty = mkCType vty
    let varcty = cgenType varty
    CG bodydecl bodyex _bodyty _bodyau <- cgenExprR env body

    let cretty = cgenType $ mkCType ty
    ret  <- freshCVar
    bumpmark <- freshCVar

    return $ CG
        (  [ cComment "sumbuild" ]
        ++ szdecl
        ++ [  "KS_ASSERT(" ++ szex ++ " > 0);",
              cretty ++ " " ++ ret ++ ";",
              "{" ]
        ++ indent (  [ varcty ++ " " ++ cgenVar var ++ " = 0;",
                       declareMark bumpmark,
                       "do {" ]
                  ++ indent (  bodydecl
                            -- First time round, deep copy it, put it in the ret, then mark the allocator
                            ++ [ "if (" ++ cgenVar var ++ " == 0) {" ]
                            ++ indent [ ret ++ " = inflated_deep_copy(" ++ allocatorParameterName ++ ", " ++ bodyex ++ ");",
                                        moveMark bumpmark allocatorParameterName ]
                            ++ [ "} else {" ]
                            ++ indent [ "inplace_add_t<"++ cretty ++">::go(&" ++ ret ++ ", " ++ bodyex ++ ");",
                                      -- Release the allocator back to where it was on iter 0
                                        resetAllocator bumpmark allocatorParameterName ]
                            ++ [ "}" ]
                            )
                  ++ [ "} while (++" ++ cgenVar var ++ " < " ++ szex ++ ");" ]
                  )
        ++ [ "}" ]
        )
        ret
        (mkCType ty)
        (if Cgen.isScalar (mkCType ty) then UsesAndResetsAllocator else UsesAllocator)

  -- Special case for literal tuples.  Don't unpack with std::get.
  -- Just use the tuple components as the arguments.  See Note [Unpack
  -- tuple arguments]
  Call tf t@(Tuple vs) -> do
    cgvs <- mapM (cgenExprR env) vs
    let cgargtype = typeof t
    let cdecls = map getDecl cgvs
    let ctypes = map getType cgvs
    let callocusage = foldMap getAllocatorUsage cgvs

    let cftype = ctypeofFun env (tf, cgargtype) ctypes

    v        <- freshCVar

    let cf = cgenAnyFun (tf, cgargtype) cftype

    return $ CG
      (  concat cdecls
      ++ [ cgenType cftype ++ " " ++ v ++ " = "
                ++ cf ++ "(" ++ cgenArgList tf (map getExpr cgvs) ++ ");" ]
      )
      v
      cftype
      (funAllocatorUsage tf cftype <> callocusage)

  Call tf@(TFun _ fun) vs -> do
    cgvs <- cgenExprR env vs
    let cgargtype = typeof vs
    let cdecls = getDecl cgvs
    let ctypes = getType cgvs
    let callocusage = getAllocatorUsage cgvs

    let cftype = ctypeofFun env (tf, cgargtype) [ctypes]

    v        <- freshCVar

    let cf = cgenAnyFun (tf, cgargtype) cftype
    let cargs = case (not (isSelFun (funIdOfFun fun)), getExpr cgvs, cgargtype) of
                  -- Untuple argument for C++ call
                  --
                  -- Calls of a tuple argument have their argument list
                  -- unpacked.  See Note [Unpack tuple arguments].
                  -- SelFuns translate to C++ get, so they don't have their
                  -- argument lists unpacked!
                  (True, cexpr, TypeTuple ts)
                    -> (flip map [0..length ts - 1] $ \i ->
                           "std::get<" ++ show i ++ ">(" ++ cexpr ++ ")")
                  (_, cexpr, _) -> [cexpr]

    return $ CG
      (  cdecls
      ++ [  cgenType cftype ++ " " ++ v ++ " = "
              ++ cf ++ "(" ++ cgenArgList tf cargs ++ ");" ]
      )
      v
      cftype
      (funAllocatorUsage tf cftype <> callocusage)

  Let (TVar _ v) e1 body -> do
    (CG decle1   ve1   type1  allocusagee1)   <- cgenExprR env e1
    (CG declbody vbody tybody allocusagebody) <- cgenExprR env body
    lvar                       <- freshCVar

    return $ CG
      (  [ cComment "Let" ++ cgenType tybody ++ " " ++ lvar ++ ";",
           "{" ]
      ++ decle1
      ++ [ cgenType type1 ++ " " ++ cgenVar v ++ " = " ++ ve1 ++ ";" ]
      ++ declbody
      ++ [ lvar ++ " = " ++ vbody ++ ";",
           "}" ]
      )
      lvar
      tybody
      (allocusagee1 <> allocusagebody)

  Tuple vs  -> do
    cgvs <- mapM (cgenExprR env) vs
    let cdecls = map getDecl cgvs
    let cexprs = map getExpr cgvs
    let ctypes = map getType cgvs
    let callocusage = foldMap getAllocatorUsage cgvs
    let ctype  = CTuple ctypes

    return $ CG (concat cdecls)
                ("std::make_tuple(" ++ intercalate "," cexprs ++ ")")
                ctype
                callocusage

  Lam param@(TVar tyv _) body -> do
    lvar <- freshCVar
    let vtype = mkCType tyv
        (params, withPackedParams) = params_withPackedParams param
    (CG cdecl cexpr ctype _callocusage) <- cgenExprR env (withPackedParams body)
    return $ CG
      (  [ cComment "Lam" ++ "auto" `spc` lvar ++ " = [=](" -- TODO: capture only freeVars here
              ++ "ks::allocator * " ++ allocatorParameterName
              ++ concatMap ((", " ++) . mkCTypedVar) params
              ++ ") {" ]
      ++ indent (  cdecl
                ++ [ "return (" ++ cexpr ++ ");" ]
                )
      ++ [ "};" ]
      )
      lvar
      (CFunction vtype ctype)
      DoesNotUseAllocator


  If c texpr fexpr -> do
    cret              <- freshCVar

    (CG declc vc _   auc) <- cgenExprR env c
    (CG declt vt tyt aut) <- cgenExprR env texpr
    (CG declf vf tyf auf) <- cgenExprR env fexpr
    let crettype = makeUnionType tyt tyf
    let dotv = case crettype of
          LMVariant _ -> ".v"  -- TODO: Ugh. Fix c++ to not require this.
          _           -> "" -- Ugh.

    return $ CG
      (  declc -- emit condition generation
      ++ [ cgenType crettype `spc` cret ++ ";", -- emit decl for "return" type
           "if (" ++ vc ++ ") {" ]
      ++ indent (  declt  -- compute true value
                ++ [ cret ++ dotv ++ " = (" ++ vt ++ ");" ]) -- assign to "return"
      ++ [ "} else {" ]
      ++ indent (  declf  -- compute false value
                ++ [ cret ++ dotv ++ " = (" ++ vf ++ ");" ]) -- assign to "return"
      ++ [ "}" ]
      )
      cret
      crettype
      (auc <> aut <> auf)

  Assert cond body -> do
    (CG declcond vcond tycond aucond) <- cgenExprR env cond
    case tycond of CType TypeBool -> return ()
                   _              -> error "tycond was not TypeBool"
    (CG declbody vbody tybody aubody) <- cgenExprR env body
    return $ CG (  makeBlock (  declcond
                             ++ [ "KS_ASSERT(" ++ vcond ++ ");" ]
                             )
                ++ declbody
                )
                vbody
                tybody
                (aucond <> aubody)

  App{} -> error "App"

substitute :: (a -> Maybe [a]) -> [a] -> [a]
substitute f = concatMap (\x -> case f x of Nothing -> [x]; Just s -> s)

mangleFun :: String -> String
mangleFun = substitute $ \case
    '@' -> Just "$a"
    ',' -> Just "$_"
    '[' -> Just "$6"
    ']' -> Just "$9"
    '<' -> Just "$d"
    '>' -> Just "$b"
    '*' -> Just "$x"
    _   -> Nothing

-- | Produces a short string that uniquely identifies the input type.
--
-- This is used to prevent name clashes between generated functions in
-- the backend. When we emit names to C/C++ we want to ensure unique
-- names for each signature.  This is required in C, and desirable in
-- C++, as otherwise delicate interactions with C++ overloading rules
-- will impose a maintenance burden.  This function generates a string
-- encoding of a type that is C-compatible, and guaranteed 1-1.
mangleType :: TypeX -> String
mangleType = \case
    TypeBool      -> "b"
    TypeInteger   -> "i"
    TypeFloat     -> "f"
    TypeString    -> "s"
    TypeTuple tys -> "<" ++ concatMap mangleType tys ++ ">"
    TypeVec ty    -> "v" ++ mangleType ty
    TypeLam a b   -> "l<" ++ mangleType a ++ mangleType b ++ ">"
    TypeLM _ _    -> error "Can't mangle TypeLM"
    TypeUnknown   -> error "Can't mangle TypeUnknown"

cgenFunId :: (FunId, Type) -> String
cgenFunId = \case
  (UserFun fun, TypeTuple [])  -> mangleFun fun
  (UserFun fun, TypeTuple tys) -> mangleFun (fun ++ "@" ++ concatMap mangleType tys)
  (UserFun fun, ty)  -> mangleFun (fun ++ "@" ++ mangleType ty)
  (PrimFun fun, _ty) -> fun
  (SelFun i _, _ty)  -> "ks::get<" ++ show (i - 1) ++ ">"

cgenUserFun :: HasCallStack => (Fun, Type) -> String
cgenUserFun (f, ty) = case f of
  Fun funId     -> cgenFunId (funId, ty)
  GradFun  s _  -> "D$" ++ cgenFunId (s, ty)
  DrvFun   s (AD BasicAD Fwd) -> "fwd$" ++ cgenFunId (s, ty)
  DrvFun   s (AD BasicAD Rev) -> "rev$" ++ cgenFunId (s, ty)
  DrvFun   s (AD TupleAD Fwd) -> "fwdt$" ++ cgenFunId (s, ty)
  DrvFun   s (AD TupleAD Rev) -> "revt$" ++ cgenFunId (s, ty)

cgenAnyFun :: HasCallStack => (TFun, Type) -> CType -> String
cgenAnyFun (tf, ty) cftype = case tf of
  TFun _ (Fun (PrimFun "lmApply")) -> "lmApply"
  TFun ty (Fun (PrimFun "build")) ->
    case ty of
      TypeVec t -> "build<" ++ cgenType (mkCType t) ++ ">"
      _         -> error ("Unexpected type for build: " ++ show ty)
  TFun ty (Fun (PrimFun "sumbuild")) -> -- TODO: remove special case
    "sumbuild<" ++ cgenType (mkCType ty) ++ ">"
  -- This is one of the LM subtypes, e.g. HCat<...>  Name is just HCat<...>::mk
  TFun (TypeLM _ _) (Fun (PrimFun _)) -> cgenType cftype ++ "::mk"
  TFun _            f                 -> cgenUserFun (f, ty)

funUsesAllocator :: HasCallStack => TFun -> Bool
funUsesAllocator (TFun _ (Fun (PrimFun fname))) =
  not $ fname `elem` ["index", "size", "eq", "ne", "delta", "$trace"]
funUsesAllocator (TFun _ (Fun (SelFun _ _))) = False
funUsesAllocator _ = True

funAllocatorUsage :: HasCallStack => TFun -> CType -> AllocatorUsage
funAllocatorUsage tf ty
  | not $ funUsesAllocator tf = DoesNotUseAllocator
  | Cgen.isScalar ty = UsesAndResetsAllocator
  | otherwise = UsesAllocator

cgenType :: HasCallStack => CType -> String
cgenType = \case
  CType  ty -> cgenTypeLang ty
  CTuple ts -> "tuple<" ++ intercalate "," (map cgenType ts) ++ ">"
  CFunction s t ->
    "std::function<" ++ cgenType t ++ "(" ++ cgenType s ++ ")>"
  TypeDef s _     -> s
  UseTypeDef s    -> s
  LMZero s t      -> lmt "Zero" [s, t]
  LMOne t         -> lmt "One" [t]
  LMScale t       -> lmt "Scale" [t]
  LMHCat   ts     -> lm "HCat" ts
  LMVCat   ts     -> lm "VCat" ts
  LMBuild  t      -> lm "Build" [t]
  LMCompose m1 m2 -> lm "Compose" [m1, m2]
  LMAdd     ms    -> lm "Add" ms
  LMVariant ts    -> lm "Variant" ts
 where
  lm s ts = "LM::" ++ s ++ "<" ++ intercalate "," (map cgenType ts) ++ ">"
  lmt s ts = "LM::" ++ s ++ "<" ++ intercalate "," (map cgenTypeLang ts) ++ ">"

cgenTypeLang :: HasCallStack => Type -> String
cgenTypeLang = \case
  TypeFloat     -> "double" -- TODO: make these all ks_Float etc, and add typedefs in knossos.h
  TypeInteger   -> "int"
  TypeString    -> "std::string"
  TypeTuple [t] -> cgenTypeLang t
  TypeTuple ts  -> "tuple<" ++ intercalate "," (map cgenTypeLang ts) ++ ">"
  TypeVec t     -> "vec<" ++ cgenTypeLang t ++ ">"
  TypeBool      -> "bool"
  TypeUnknown   -> "void"
  TypeLam from to ->
    "std::function<" ++ cgenTypeLang to ++ "(" ++ cgenTypeLang from ++ ")>"
  TypeLM s t -> error $ "LM<" ++ cgenTypeLang s ++ "," ++ cgenTypeLang t ++ ">"

ctypeofFun :: HasCallStack => CST -> (TFun, Type) -> [CType] -> CType
ctypeofFun env (TFun ty f, argty) ctys = case cstMaybeLookupFun (f, argty) env of
  Just _ -> -- trace ("Found fun " ++ show f) $
    UseTypeDef ("ty$" ++ cgenUserFun (f, argty))
  Nothing -> -- trace ("Did not find fun " ++ show tf ++ " in\n     " ++ show env) $
    ctypeofFun1 ty f ctys

ctypeofFun1 :: HasCallStack => Type -> Fun -> [CType] -> CType
ctypeofFun1 ty (Fun (PrimFun name)) ctys = ctypeofPrimFun ty name ctys
ctypeofFun1 (TypeLM _ _) (GradFun f _) ctys = ctypeofGradBuiltin f ctys
ctypeofFun1 (TypeLM _ _) f ctys =
  error $ "Did not match [" ++ show f ++ "]@\n  " ++ intercalate
    "\n  "
    (map show ctys)
ctypeofFun1 ty _ _ = mkCType ty

ctypeofPrimFun :: HasCallStack => Type -> String -> [CType] -> CType
ctypeofPrimFun ty s arg_types = case (s, map stripTypeDef arg_types) of
  ("lmApply"  , _         ) -> mkCType ty
  ("lmOne"    , [ct]      ) -> LMOne (stripCType ct)
  ("lmZero"   , [cs, ct]  ) -> LMZero (stripCType cs) (stripCType ct)
  ("lmScale"  , [ct, CType TypeFloat]) -> LMScale (stripCType ct)
  ("lmHCat"   , _         ) -> LMHCat arg_types
  ("lmVCat"   , _         ) -> LMVCat arg_types
  ("lmCompose", [lm1, lm2]) -> LMCompose lm1 lm2
  ("lmAdd"    , _         ) -> LMAdd arg_types
  ("lmVariant", _         ) -> LMVariant arg_types
  _                         -> case ty of
    TypeLM _ _ -> error
      (  "Unmatched prim ["
      ++ s
      ++ "] "
      ++ show ty
      ++ " @\n"
      ++ "  "
      ++ intercalate "\n  " (map show arg_types)
      )
    _ -> mkCType ty

pattern RR :: TypeX
pattern RR = TypeFloat

ctypeofGradBuiltin :: HasCallStack => FunId -> [CType] -> CType
ctypeofGradBuiltin f ctys = case (f, map stripTypeDef ctys) of
  (PrimFun "ts_add"  , [CType RR, CType RR]) -> LMHCat [LMScale RR, LMScale RR]
  (PrimFun "$trace"  , [CType ty]          ) -> LMOne ty
  (PrimFun "size"    , [CType ty]          ) -> LMZero ty TypeInteger
  (PrimFun "index"   , [CType (TypeVec t)])-> trace "LMIndex?" $ LMHCat [LMZero TypeInteger t, LMBuild (LMScale t)]
  _ -> error $ "Don't know grad of [" ++ show f ++ "]@\n  " ++ intercalate
    "\n  "
    (map (show . stripTypeDef) ctys)

cgenKonst :: Konst -> String
cgenKonst = \case
  KInteger i -> show i
  KFloat   f -> show f
  KString  s -> show s
  KBool    b -> if b then "1 " ++ cComment "TRUE" else "0 " ++ cComment "FALSE"

cgenVar :: Var -> String
cgenVar = render . ppr

makeDirectoryForFile :: FilePath -> IO ()
makeDirectoryForFile =
  System.Directory.createDirectoryIfMissing True
  . fst
  . System.FilePath.splitFileName

createDirectoryWriteFile :: FilePath -> String -> IO ()
createDirectoryWriteFile filepath contents = do
  makeDirectoryForFile filepath
  writeFile filepath contents

cppGenWithFiles :: String -> String -> [TDef] -> IO ()
cppGenWithFiles ksofile cppfile defs = do
  let lines =
        [
        "#include \"knossos.h\"",
        "namespace ks {\n"
        ]
      lls   = cgenDefs defs
      tail =
        [ "}"
        , "#include \"knossos.cpp\""
        , "// cppGen automatically generates a call to ks::main()."
        , "// Some of the files we want to compile don't have a main."
        , "// The simplest way of allowing them to compile is generate"
        , "// a declaration for ks::main().  We have to choose a return"
        , "// type for it.  int is a reasonable choice.  In the future"
        , "// should try to improve the compile pipeline so it doesn't"
        , "// always insert a call to ks::main()."
        , "namespace ks { int main(allocator *); }"
        , "int main() {"
        , "  ks::allocator alloc{ 1'000'000'000 };"
        , "  ks::main(&alloc);"
        , "  return 0;"
        , "}"
        ]

  putStrLn $ "Writing to " ++ ksofile
  createDirectoryWriteFile ksofile (unlines (map (renderSexp . ppr) defs))

  putStrLn $ "Writing to " ++ cppfile
  createDirectoryWriteFile cppfile (unlines (lines ++ lls ++ tail))

compile :: String -> String -> String -> IO String
compile = compileWithOpts []

compileWithProfiling :: String -> String -> String -> IO String
compileWithProfiling =
  compileWithOpts ["-Wl,--no-as-needed,-lprofiler,--as-needed"]

compileWithOpts :: [String] -> String -> String -> String -> IO String
compileWithOpts opts compilername cppfile exefile = do
  let compcmd =
        ( compilername
        , [ "-fmax-errors=5"
          , "-fdiagnostics-color=always"
          , "-Wall"
          , "-Wno-unused"
          , "-Wno-maybe-uninitialized"
          , "-Isrc/runtime"
          , "-O3"
          , "-g"
          , "-std=c++17"
          , "-o"
          , exefile
          ]
          ++ opts
          ++ [cppfile]
        )
  makeDirectoryForFile exefile
  putStrLn $ "Compiling: " ++ fst compcmd ++ " " ++ unwords (snd compcmd)
  uncurry readProcessPrintStderr compcmd
  return exefile

runExe :: String -> IO String
runExe exefile = do
  putStrLn "Running"
  readProcessPrintStderr exefile []

readProcessEnv
  :: FilePath -> [String] -> Maybe [(String, String)] -> IO (ExitCode, String, String)
readProcessEnv executable args env = do
  let stdin = ""
  System.Process.readCreateProcessWithExitCode
    (System.Process.proc executable args) { System.Process.env = env }
    stdin

readProcessEnvPrintStderr
  :: FilePath -> [String] -> Maybe [(String, String)] -> IO String
readProcessEnvPrintStderr executable args env = do
  (exitCode, stdout, stderr) <- readProcessEnv executable args env
  putStr stderr
  when (exitCode /= ExitSuccess) $ error "Compilation failed"
  return stdout

readProcessPrintStderrOnFail
  :: FilePath -> [String] -> IO String
readProcessPrintStderrOnFail executable args = do
  (exitCode, stdout, stderr) <- readProcessEnv executable args Nothing
  when (exitCode /= ExitSuccess) $ do
    putStr stderr
    error "Compilation failed"
  return stdout

readProcessPrintStderr :: FilePath -> [String] -> IO String
readProcessPrintStderr executable args =
  readProcessEnvPrintStderr executable args Nothing
