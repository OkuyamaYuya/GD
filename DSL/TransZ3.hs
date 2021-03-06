module TransZ3 ( transZ3,
                 getInfo,
                 z3MonotoneR,
                 z3MonotoneQ
                 -- z3Connected
               ) where

import Base
import Lex
import Parse
import Syntax
import Typecheck
import Data.Map as Map
import Data.List (isInfixOf)
import Debug.Trace

z3MonotoneR = "./temp/testMonotoneR.z3"
z3MonotoneQ = "./temp/testMonotoneQ.z3"
-- z3Connected = "./temp/testConnected.z3"

transZ3 :: Result Program -> ENV_ty -> IO String
transZ3 prog env = case prog of
  Reject err -> return err
  Accept (Program ss) ->
    case getInfo ss of
      Reject err -> return err
      Accept (_,rr,it,ot,lx,lq) -> do
        let template = header it lx ++ (unlines $ fmap (transZ3_ env) ss)
        writeFile z3MonotoneR (template ++ makeQuery rr it ot "r")
        writeFile z3MonotoneQ (template ++ makeQuery rr it ot "q")
        return template

type Used = Bool

getInfo :: [Sentence] -> Result ([String],[String],TY,TY,Used,Used)
getInfo ss =
  let ll = findLeft ss
      rr = findRight ss
      it = findItype ss
      ot = findOtype ss
      lx = findLexico ss
      lq = findLeq ss
  in
    case (ll,rr,it,ot) of
      (Nothing,_,_,_) -> 
        Reject "write 'LEFT'."
      (_,Nothing,_,_) -> 
        Reject "write 'RIGHT'."
      (_,_,Nothing,_) -> 
        Reject "write 'ITYPE'."
      (_,_,_,Nothing) -> 
        Reject "write 'OTYPE'."
      (Just jll,Just jrr,Just jit,Just jot) -> 
        Accept (fmap showExpr jll,fmap showExpr jrr,jit,jot,lx,lq)
  where
    -- find leftmost one.
    findRight [] = Nothing
    findRight ((RIGHT x):xs) = Just x
    findRight (_:xs) = findRight xs
    findLeft [] = Nothing
    findLeft ((LEFT x):xs) = Just x
    findLeft (_:xs) = findLeft xs
    findItype [] = Nothing
    findItype ((ITYPE x):xs) = Just x
    findItype (_:xs) = findItype xs
    findOtype [] = Nothing
    findOtype ((OTYPE x):xs) = Just x
    findOtype (_:xs) = findOtype xs
    findLexico [] = False
    findLexico ((BIND _ _ _ e):xs)
      | isInfixOf "leq_lexico" (show e) = True
      | otherwise = findLexico xs
    findLexico (_:xs) = findLexico xs
    findLeq [] = False
    findLeq ((BIND _ _ _ e):xs)
      | isInfixOf "leq" (show e) = True
      | otherwise = findLeq xs
    findLeq (_:xs) = findLeq xs

transZ3_ _ (LEFT _) = ""
transZ3_ _ (RIGHT _) = ""
transZ3_ _ (ITYPE _) = ""
transZ3_ _ (OTYPE _) = ""
transZ3_ _ (INSTANCE _) = ""
transZ3_ _ COMMENTOUT = ""
transZ3_ typEnv (BIND varName varArgs varType varExpr) = case varExpr of
  VAR _ -> case varType of
            FUN _ _ -> defineFun varName varArgs varType varExpr typEnv
            _       -> defineConst varName varType varExpr
  FOLDR _ _ -> declareRecFun varName varType varExpr
  _ -> case varType of
        FUN _ _ -> defineFun varName varArgs varType varExpr typEnv
        _       -> defineConst varName varType varExpr

-- [x,y] -> (a -> b -> c) -> "((x a) (y b)) (c)"
argTuple :: [String] -> TY -> String
argTuple as ts = concat $ zipWith aux as (dom $ ts)
  where aux x t = "(" ++ x ++ " " ++ t ++ ")"

-- ["x1 ","x2 ","x3 "..]
argSequence sz = fmap (\i -> "x" ++ show i ++ " ") [1..sz]

-- FUN a (FUN b c) -> [a,b]
dom :: TY -> [String]
dom (FUN a b) = showType a : dom b
dom _         = []

cod :: TY -> String
cod (FUN a b) = cod b
cod a = showType a

defineConst x typ v = unlines [a1,a2]
  where
    a1 = "(define-const " ++ x ++ " " ++ showType typ
    a2 = showExpr v ++ ")"

-- (define-fun f ((x t1) (y t2)) t3 
--   hogehoge )
defineFun f as typ expr env = unlines [a1,a2]
  where
    a1 = "(define-fun " ++ f ++ " (" ++ argTuple args typ ++ ")" ++ cod typ
    a2
      | isFunctionOrNot expr = "(" ++ showExpr expr ++ " " ++ concat argsMk ++ "))"
      | otherwise = showExpr expr ++ " " ++ concat argsMk ++ ")"
    argsMk = argSequence (length (dom typ) - length as)
    args = as ++ argsMk
    isFunctionOrNot e = case tycheck_ e env of
      FUN _ _ -> True
      _ -> False

-- (declare-fun pair-sum ((List (Pair Int Int))) (Pair Int Int))
-- (assert (forall ((xs (List (Pair Int Int))))
--           (ite (= nil xs)
--                (= (mk-pair 0 0)                              (pair-sum xs))
--                (= (pair-plus (head xs) (pair-sum (tail xs))) (pair-sum xs)))))
declareRecFun recfun typ (FOLDR (VAR f) e) = unlines [a1,a2,a3,a4,a5]
  where
    a1 = "(declare-fun " ++ recfun ++ " " ++ showType typ ++ ")"
    a2 = "(assert (forall ((xs " ++ showType (dom typ) ++ "))"
    a3 = "  (ite (= nil xs)"
    a4 = "       (= " ++ showExpr e ++ "    (" ++ recfun ++ " xs))"
    a5 = "       (= (" ++ f ++ " (head xs) (" ++ recfun ++ "(tail xs))) (" ++ recfun ++ " xs)))))"
    dom (FUN a b) = a
declareRecFun recfun typ (FOLDR _ e) = "ERROR"


-- Types of cons,outr,nil depend on a problem user defines.
header :: TY -> Used -> String
header it lx = unlines $ [ 
    "(declare-datatypes (T1 T2) ((Pair (mk-pair (fst T1) (snd T2)))))",
    "(define-fun cons ((x "++showType it++") (y (List"++showType it++"))) (List "++showType it++")",
    "  (insert x y))",
    "(define-fun outr ((x "++showType it++") (y (List"++showType it++"))) (List "++showType it++")",
    "  y)",
    "(define-fun leq ((x Int) (y Int)) Bool",
    "(<= x y))" ] ++
      if lx then [
    "(declare-fun leq_lexico ((List Int) (List Int)) Bool)",
    "(assert (forall ((xs (List Int)) (ys (List Int)))",
    "  (= (leq_lexico xs ys)",
    "  (or",
    "    (= xs nil)",
    "    (< (head xs) (head ys))",
    "    (and (= (head xs) (head ys))",
    "         (leq_lexico (tail xs) (tail ys)))))))" ] else [""]


makeQuery :: [String] -> TY -> TY -> String -> String
makeQuery fs it ot order = "(push)\n" ++
                  a1 ++ a2 ++ a3 ++ 
                  "\n(check-sat)\n(pop)"
  where
    a1 = unlines $ fmap declareBool fs
    a2 = do
      f <- fs
      mainQuery f fs it ot order
    a3 = lastQuery fs

-- (declare-const b Bool)
declareBool f = "(declare-const " ++ bf ++ " Bool)"
  where bf = "b" ++ f

-- (assert (not (b1 b2 ..)))
lastQuery fs = "(assert (not (and " ++ aux fs ++ ")))"
  where
    aux xs = concat.prepare $ xs
    prepare xs = fmap (\x->"b"++x++" ") xs

-- Better-Local monotonicity check
-- q : local criterion
-- (assert (forall ((x T)(y T)..)
--  hogehoge
-- ))
mainQuery f fs itype otype order =
  let bf = "b" ++ f in
    unlines $ [
    "(assert (= " ++ bf,
    "    (forall ((xs " ++ ot ++ ") (ys " ++ ot ++ ") (a " ++ it ++ "))",
    "    (=> (" ++ order ++ " ys xs) ",
    "    (=> (p (" ++ f ++ " a ys))",
    "        (or "] ++ fmap (target f) fs ++ ["))))))"]
      where
        it = showType itype
        ot = showType otype
        target f g = "\t(and (p (" ++ g ++ " a xs)) (" ++ order ++
                     " (" ++ f ++ " a ys) (" ++ g++ " a xs)))"

