
-- TODO items: lambda params, define, a simple test suite

{- |
Module      : Language.Scheme.Core
Copyright   : Justin Ethier
Licence     : MIT (see LICENSE in the distribution)

Maintainer  : github.com/justinethier
Stability   : experimental
Portability : portable

This module contains an experimental compiler of Scheme to Haskell 

The compiler performs the following transformations:
Scheme AST (LispVal) -> Haskell AST (HaskAST) -> Compiled Code (String)
-}

module Language.Scheme.Compiler where 
import qualified Language.Scheme.Macro
import Language.Scheme.Numerical
import Language.Scheme.Parser
import Language.Scheme.Primitives
import Language.Scheme.Types
import Language.Scheme.Variables
import Control.Monad.Error
import qualified Data.Array
import Data.Complex
import qualified Data.List
import Data.Ratio
import System.IO
import Debug.Trace

-- A type to store options passed to compile
-- eventually all of this might be able to be integrated into a Compile monad
data CompOpts = CompileOptions {
    coptsThisFunc :: String,
    coptsThisFuncUseValue :: Bool,
    coptsThisFuncUseArgs :: Bool,
    coptsNextFunc :: Maybe String
    }
--DefaultCompileOptions :: String -> CompileOpts 
defaultCompileOptions :: String -> CompOpts
defaultCompileOptions thisFunc = CompileOptions thisFunc False False Nothing

createAstFunc :: CompOpts -> [HaskAST] -> HaskAST 
createAstFunc (CompileOptions thisFunc useVal useArgs _) body = do
  let val = case useVal of
              True -> "value"
              _ -> "_"
      args = case useArgs of
               True -> "(Just args)"
               _ -> "_"
  AstFunction thisFunc (" env cont " ++ val ++ " " ++ args ++ " ") body

createAstCont :: CompOpts -> String -> String -> HaskAST
createAstCont (CompileOptions _ _ _ (Just nextFunc)) var indentation = do
  AstValue $ indentation ++ "  continueEval env (makeCPS env cont " ++ nextFunc ++ ") " ++ var
createAstCont (CompileOptions _ _ _ Nothing) var indentation = do
  AstValue $ indentation ++ "  continueEval env cont " ++ var

-- A very basic type to store a Haskell AST
data HaskAST = AstAssignM String HaskAST
  | AstFunction {astfName :: String,
--                 astfType :: String,
                 astfArgs :: String,
                 astfCode :: [HaskAST]
                } 
 | AstValue String
 | AstContinuation {astcNext :: String,
                    astcArgs :: String
                   }

showValAST :: HaskAST -> String
showValAST (AstAssignM var val) = "  " ++ var ++ " <- " ++ show val
showValAST (AstFunction name args code) = do
  let header = "\n" ++ name ++ args ++ " = do "
  let body = unwords . map (\x -> "\n" ++ x ) $ map showValAST code
  header ++ body 
showValAST (AstValue v) = v

-- TODO: this is too limiting, this is an 'internal' continuation. most should take a value and pass it along, not args
showValAST (AstContinuation nextFunc args) = "  continueEval env (makeCPSWArgs env cont " ++ nextFunc ++ " " ++ args ++ ") $ Nil \"\""

instance Show HaskAST where show = showValAST

joinL ls sep = concat $ Data.List.intersperse sep ls

astToHaskellStr :: LispVal -> String 
astToHaskellStr (String s) = "String " ++ show s
astToHaskellStr (Char c) = "Char " ++ show c
astToHaskellStr (Atom a) = "Atom " ++ show a
astToHaskellStr (Number n) = "Number " ++ show n
astToHaskellStr (Complex c) = "Complex $ " ++ (show $ realPart c) ++ " :+ " ++ (show $ imagPart c)
astToHaskellStr (Rational r) = "Rational $ " ++ (show $ numerator r) ++ " % " ++ (show $ denominator r)
astToHaskellStr (Float f) = "Float " ++ show f
astToHaskellStr (Bool True) = "Bool True"
astToHaskellStr (Bool False) = "Bool False"
astToHaskellStr (Vector v) = do
  let ls = Data.Array.elems v
      size = (length ls) - 1
  "Vector (listArray (0, " ++ show size ++ ")" ++ "[" ++ joinL (map astToHaskellStr ls) "," ++ "])"
astToHaskellStr (List ls) = "List [" ++ joinL (map astToHaskellStr ls) "," ++ "]"
astToHaskellStr (DottedList ls l) = 
  "DottedList [" ++ joinL (map astToHaskellStr ls) "," ++ "] $ " ++ astToHaskellStr l

header :: [String]
header = [
   "module Main where "
-- Currently not used: , "import Language.Scheme.Compiler.Helpers "
 , "import Language.Scheme.Core "
 , "import Language.Scheme.Numerical "
 , "import Language.Scheme.Primitives "
 , "import Language.Scheme.Types     -- Scheme data types "
 , "import Language.Scheme.Variables -- Scheme variable operations "
 , "import Control.Monad.Error "
 , "import Data.Array "
 , "import Data.Complex "
 , "import Data.Ratio "
 , "import System.IO "
 , " "
-- TODO: eventually these make func's will be moved out into their own module
 , ""
 , "--makeNormalFunc :: Env -> [LispVal] -> String -> IOThrowsError LispVal "
 , "makeHFunc ::"
 , "            (Monad m) =>"
 , "            Maybe String "
 , "         -> Env "
 , "         -> [String] "
 , "         -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal) "
 , "--         -> String "
 , "         -> m LispVal"
 , "makeHFunc varargs env fparams fbody = return $ HFunc fparams varargs fbody env --(map showVal fparams) varargs fbody env"
 , "makeNormalHFunc :: (Monad m) =>"
 , "                  Env"
 , "               -> [String]"
 , "               -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal)"
 , "               -> m LispVal"
 , "makeNormalHFunc = makeHFunc Nothing"
 , "makeHVarargs :: (Monad m) => LispVal "
 , "                        -> Env"
 , "                        -> [String]"
 , "                        -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal)"
 , "                        -> m LispVal"
 , "makeHVarargs = makeHFunc . Just . showVal"
 , "main :: IO () "
 , "main = do "
 , "  env <- primitiveBindings "
 , "  (runIOThrows $ liftM show $ run env (makeNullContinuation env) (Nil \"\") Nothing) >>= putStr "
 , " "]

-- NOTE: the following type is used for all functions generated by the compiler: 
-- , "run :: Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal "

compileLisp :: Env -> String -> String -> IOThrowsError [HaskAST]
compileLisp env filename entryPoint = load filename >>= compileBlock entryPoint env []
-- compileBlock
--
-- Note: Uses explicit recursion to transform a block of code, because
--  later lines may depend on previous ones
compileBlock :: String -> Env -> [HaskAST] -> [LispVal] -> IOThrowsError [HaskAST]
compileBlock symThisFunc env result code@[c] = do
--  Atom symThisFunc <- _gensym "f"
  compiled <- mcompile env c $ defaultCompileOptions symThisFunc 
  return $ result ++ compiled
compileBlock symThisFunc env result code@(c:cs) = do
--  Atom symThisFunc <- _gensym "f"
  Atom symNextFunc <- _gensym "f"
  compiled <- mcompile env c $ CompileOptions symThisFunc False False (Just symNextFunc)
  compileBlock symNextFunc env (result ++ compiled) cs
compileBlock _ _ result [] = return result

-- TODO: could everything just be regular function calls except when a continuation is 'added to the stack' via a makeCPS(makeCPSWArgs ...) ?? I think this could be made more efficient

-- Helper function to compile expressions consisting of a scalar
compileScalar :: String -> CompOpts -> IOThrowsError [HaskAST]
compileScalar val copts = do 
  f <- return $ AstAssignM "x1" $ AstValue val 
  c <- return $ createAstCont copts "x1" ""
  return [createAstFunc copts [f, c]]

compileLambdaList :: [LispVal] -> IOThrowsError String
compileLambdaList l = do
  serialized <- mapM serialize l 
  return $ "[" ++ concat (Data.List.intersperse "," serialized) ++ "]"
 where serialize (Atom a) = return $ (show a)
       --serialize _ = throwError $ Default "invalid parameter to lambda list. TODO: output var"

compile :: Env -> LispVal -> CompOpts -> IOThrowsError [HaskAST]
compile _ (Nil n) copts = compileScalar ("  return $ Nil " ++ (show n)) copts
compile _ (String s) copts = compileScalar ("  return $ String " ++ (show s)) copts
compile _ (Char c) copts = compileScalar ("  return $ Char " ++ (show c)) copts
compile _ (Complex c) copts = compileScalar ("  return $ Complex $ " ++ (show $ realPart c) ++ " :+ " ++ (show $ imagPart c)) copts
compile _ (Float f) copts = compileScalar ("  return $ Float " ++ (show f)) copts
compile _ (Rational r) copts = compileScalar ("  return $ Rational $ " ++ (show $ numerator r) ++ " % " ++ (show $ denominator r)) copts 
compile _ (Number n) copts = compileScalar ("  return $ Number " ++ (show n)) copts
compile _ (Bool b) copts = compileScalar ("  return $ Bool " ++ (show b)) copts
-- TODO: eval env cont val@(HashTable _) = continueEval env cont val
-- TODO: eval env cont val@(Vector _) = do
compile _ (Atom a) copts = compileScalar ("  getVar env \"" ++ a ++ "\"") copts 

compile _ (List [Atom "quote", val]) copts = compileScalar (" return $ " ++ astToHaskellStr val) copts

-- TODO: quasiquote
-- TODO: other special forms...

compile env args@(List [Atom "define-syntax", Atom keyword, (List (Atom "syntax-rules" : (List identifiers : rules)))]) copts = do
--
-- TODO:
--
-- macros will eventually need to introduce a definition in both the compiler's env (so macros can be processed at compile time) and in the program's env (so dynamically injected code has access to the macro). That said, the priority is compile-time processing.
  _ <- defineNamespacedVar env macroNamespace keyword $ Syntax (Just env) Nothing False identifiers rules
  compileScalar ("  return $ Nil \"\"") copts 

-- TODO: eval env cont fargs@(List (Atom "begin" : funcs)) = do
-- TODO: set!

compile env args@(List [Atom "if", predic, conseq]) copts = 
 compile env (List [Atom "if", predic, conseq, Nil ""]) copts

compile env args@(List [Atom "if", predic, conseq, alt]) copts@(CompileOptions thisFunc _ _ nextFunc) = do
 -- TODO: think about it, these could probably be part of compileExpr
 Atom symPredicate <- _gensym "ifPredic"
 Atom symCheckPredicate <- _gensym "compiledIfPredicate"
 Atom symConsequence <- _gensym "compiledConsequence"
 Atom symAlternate <- _gensym "compiledAlternative"
 -- Entry point; ensure if is not rebound
 f <- return $ [AstValue $ "  bound <- liftIO $ isRecBound env \"if\"",
       AstValue $ "  if bound ",
       AstValue $ "     then throwError $ NotImplemented \"prepareApply env cont args\" ", -- if is bound to a variable in this scope; call into it
       AstValue $ "     else do " ++ symPredicate ++ " env (makeCPS env cont " ++ symCheckPredicate ++ ") (Nil \"\") [] "
       ]
 -- Compile expression for if's args
 compPredicate <- compileExpr env predic symPredicate Nothing      -- Do not want to call into nextFunc in the middle of (if)
 compConsequence <- compileExpr env conseq symConsequence nextFunc -- pick up at nextFunc after consequence
 compAlternate <- compileExpr env alt symAlternate nextFunc        -- or...pick up at nextFunc after alternate
 -- Special case because we need to check the predicate's value
 compCheckPredicate <- return $ AstFunction symCheckPredicate " env cont result _ " [
    AstValue $ "  case result of ",
    AstValue $ "    Bool False -> " ++ symAlternate ++ " env cont (Nil \"\") [] ",
    AstValue $ "    _ -> " ++ symConsequence ++ " env cont (Nil \"\") [] "]
 -- Join compiled code together
 return $ [createAstFunc copts f] ++ compPredicate ++ [compCheckPredicate] ++ compConsequence ++ compAlternate

compile env args@(List [Atom "define", Atom var, form]) copts@(CompileOptions thisFunc _ _ nextFunc) = do
 Atom symDefine <- _gensym "defineFuncDefine"
 Atom symMakeDefine <- _gensym "defineFuncMakeDef"

 -- Entry point; ensure var is not rebound
 f <- return $ [AstValue $ "  bound <- liftIO $ isRecBound env \"define\"",
       AstValue $ "  if bound ",
       AstValue $ "     then throwError $ NotImplemented \"prepareApply env cont args\" ", -- if is bound to a variable in this scope; call into it
       AstValue $ "     else do " ++ symDefine ++ " env cont (Nil \"\") []" ]
 compDefine <- compileExpr env form symDefine $ Just symMakeDefine
 compMakeDefine <- return $ AstFunction symMakeDefine " env cont result _ " [
    AstValue $ "  _ <- defineVar env \"" ++ var ++ "\" result",
    createAstCont copts "result" ""]
 return $ [createAstFunc copts f] ++ compDefine ++ [compMakeDefine]

compile env args@(List (Atom "define" : List (Atom var : fparams) : fbody)) copts@(CompileOptions thisFunc _ _ nextFunc) = do
 Atom symCallfunc <- _gensym "defineFuncEntryPt"
 compiledParams <- compileLambdaList fparams
 compiledBody <- compileBlock symCallfunc env [] fbody

 -- Entry point; ensure var is not rebound
 f <- return $ [AstValue $ "  bound <- liftIO $ isRecBound env \"define\"",
       AstValue $ "  if bound ",
       AstValue $ "     then throwError $ NotImplemented \"prepareApply env cont args\" ", -- if is bound to a variable in this scope; call into it
       AstValue $ "     else do result <- makeNormalHFunc env (" ++ compiledParams ++ ") " ++ symCallfunc,
       AstValue $ "             _ <- defineVar env \"" ++ var ++ "\" result ",
       createAstCont copts "result" "           "
       ]
 return $ [createAstFunc copts f] ++ compiledBody

-- TODO: eval env cont args@(List (Atom "define" : DottedList (Atom var : fparams) varargs : fbody)) = do
compile env args@(List (Atom "define" : DottedList (Atom var : fparams) varargs : fbody)) copts@(CompileOptions thisFunc _ _ nextFunc) = do
 Atom symCallfunc <- _gensym "defineFuncEntryPt"
 compiledParams <- compileLambdaList fparams
 compiledBody <- compileBlock symCallfunc env [] fbody

 -- Entry point; ensure var is not rebound
 f <- return $ [AstValue $ "  bound <- liftIO $ isRecBound env \"define\"",
       AstValue $ "  if bound ",
       AstValue $ "     then throwError $ NotImplemented \"prepareApply env cont args\" ", -- if is bound to a variable in this scope; call into it
       AstValue $ "     else do result <- makeHVarargs (" ++ astToHaskellStr varargs ++ ") env (" ++ compiledParams ++ ") " ++ symCallfunc,
       AstValue $ "             _ <- defineVar env \"" ++ var ++ "\" result ",
       createAstCont copts "result" "           "
       ]
 return $ [createAstFunc copts f] ++ compiledBody



compile env args@(List (Atom "lambda" : List fparams : fbody)) copts@(CompileOptions thisFunc _ _ nextFunc) = do
 Atom symCallfunc <- _gensym "lambdaFuncEntryPt"
 compiledParams <- compileLambdaList fparams

-- TODO: need to extend Env below when compiling body?
-- TODO: need to bind lambda params in the extended env, for purposes of macro processing?

 compiledBody <- compileBlock symCallfunc env [] fbody

 -- Entry point; ensure var is not rebound
-- TODO: will probably end up creating a common function for this,
--       since it is almost the same as in "if"
 f <- return $ [AstValue $ "  bound <- liftIO $ isRecBound env \"lambda\"",
       AstValue $ "  if bound ",
       AstValue $ "     then throwError $ NotImplemented \"prepareApply env cont args\" ", -- if is bound to a variable in this scope; call into it
       AstValue $ "     else do result <- makeNormalHFunc env (" ++ compiledParams ++ ") " ++ symCallfunc,
       createAstCont copts "result" "           "
       ]
 return $ [createAstFunc copts f] ++ compiledBody



-- TODO: eval env cont args@(List (Atom "lambda" : DottedList fparams varargs : fbody)) = do
-- TODO: eval env cont args@(List (Atom "lambda" : varargs@(Atom _) : fbody)) = do



compile env args@(List (_ : _)) copts = mfunc env args compileApply copts 
compile _ badForm _ = throwError $ BadSpecialForm "Unrecognized special form" badForm

mcompile :: Env -> LispVal -> CompOpts -> IOThrowsError [HaskAST]
mcompile env lisp copts = mfunc env lisp compile copts
mfunc :: Env -> LispVal -> (Env -> LispVal -> CompOpts -> IOThrowsError [HaskAST]) -> CompOpts -> IOThrowsError [HaskAST] 
mfunc env lisp func copts = do
  transformed <- Language.Scheme.Macro.macroEval env lisp 
  func env transformed copts
{- TODO: adapt for compilation
meval, mprepareApply :: Env -> LispVal -> LispVal -> IOThrowsError LispVal
meval env cont lisp = mfunc env cont lisp eval
mprepareApply env cont lisp = mfunc env cont lisp prepareApply
mfunc :: Env -> LispVal -> LispVal -> (Env -> LispVal -> LispVal -> IOThrowsError LispVal) -> IOThrowsError LispVal
mfunc env cont lisp func = do
  Language.Scheme.Macro.macroEval env lisp >>= (func env cont) 
-}

-- Compile an intermediate expression (such as an arg to if) and 
-- call into the next continuation with it's value
compileExpr :: Env -> LispVal -> String -> Maybe String -> IOThrowsError [HaskAST]
compileExpr env expr symThisFunc fForNextExpr = do
  mcompile env expr (CompileOptions symThisFunc False False fForNextExpr) 

-- |Compiles each argument to a function call, and then uses apply to call the function
compileApply :: Env -> LispVal -> CompOpts -> IOThrowsError [HaskAST]
compileApply env args@(List (func : params)) copts@(CompileOptions coptsThis _ _ coptsNext) = do
  Atom stubFunc <- _gensym "applyStubF"
  Atom wrapperFunc <- _gensym "applyWrapper"
  Atom nextFunc <- _gensym "applyNextF"

  c <- return $ AstFunction coptsThis " env cont _ _ " [AstValue $ "  continueEval env (makeCPS env (makeCPS env cont " ++ wrapperFunc ++ ") " ++ stubFunc ++ ") $ Nil\"\""]  
  -- Use wrapper to pass high-order function (func) as an argument to apply
  wrapper <- return $ AstFunction wrapperFunc " env cont value _ " [AstValue $ "  continueEval env (makeCPSWArgs env cont " ++ nextFunc ++ " [value]) $ Nil \"\""]
  _comp <- mcompile env func $ CompileOptions stubFunc False False Nothing
  rest <- compileArgs nextFunc False params -- False since no value passed in this time

  return $ [c, wrapper ] ++ _comp ++ rest
 where 
  -- TODO: this pattern may need to be extracted into a common place for use in other similar
  --       situations, such as params to a lambda expression
  compileArgs :: String -> Bool -> [LispVal] -> IOThrowsError [HaskAST]
  compileArgs thisFunc thisFuncUseValue args = do
    case args of
      [] -> do
           -- The basic idea is that if there is a next expression, call into it as a new continuation
           -- instead of calling into cont
           case coptsNext of
             Nothing -> return $ [
               AstFunction thisFunc 
                " env cont (Nil _) (Just (a:as)) " [AstValue "  apply cont a as "],
               AstFunction thisFunc 
                " env cont value (Just (a:as)) " [AstValue "  apply cont a $ as ++ [value] "]]
             Just fnextExpr -> return $ [
               AstFunction thisFunc 
                " env cont (Nil _) (Just (a:as)) " [AstValue $ "  apply (makeCPS env cont " ++ fnextExpr ++ ") a as "],
               AstFunction thisFunc 
                " env cont value (Just (a:as)) " [AstValue $ "  apply (makeCPS env cont " ++ fnextExpr ++ ") a $ as ++ [value] "]]
      (a:as) -> do
        Atom stubFunc <- _gensym "applyFirstArg" -- Call into compiled stub
        Atom nextFunc <- _gensym "applyNextArg" -- Next func argument to execute...
        _comp <- mcompile env a $ CompileOptions stubFunc False False Nothing

        -- Flag below means that the expression's value matters, add it to args
        f <- if thisFuncUseValue
                then return $ AstValue $ thisFunc ++ " env cont value (Just args) = do "
                else return $ AstValue $ thisFunc ++ " env cont _ (Just args) = do "
        c <- if thisFuncUseValue
                then return $ AstValue $ "  continueEval env (makeCPS env (makeCPSWArgs env cont " ++ nextFunc ++ " $ args ++ [value]) " ++ stubFunc ++ ") $ Nil\"\""  
                else return $ AstValue $ "  continueEval env (makeCPS env (makeCPSWArgs env cont " ++ nextFunc ++ " args) " ++ stubFunc ++ ") $ Nil\"\""  

        rest <- compileArgs nextFunc True as -- True indicates nextFunc needs to use value arg passed into it
        return $ [ f, c] ++ _comp ++ rest

