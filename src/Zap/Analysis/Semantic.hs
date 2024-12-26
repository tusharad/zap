{-# LANGUAGE OverloadedStrings #-}
module Zap.Analysis.Semantic
  ( analyze
  , SemanticError(..)
  ) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import qualified Data.Map.Strict as M
import Debug.Trace

import Zap.AST

data SemanticError
  = EmptyStringLiteral
  | UndefinedVariable String
  | UndefinedStruct String
  | UndefinedField String String
  | UndefinedFunction String
  | TypeMismatch Type Type
  | TypeMismatchInOp Op Type Type
  | TypeMismatchInFunction String Type Type
  | ArgumentCountMismatch String Int Int
  | InvalidBreak String
  | InvalidVectorComponents VecType [Type]
  | IndexNotInteger Type
  | ResultOutsideBlock
  | IncompatibleTypes String Type Type
  | RecursionInGlobalScope String
  deriving (Show, Eq)

data FuncSig = FuncSig [Type] Type
  deriving (Show, Eq)

type VarEnv = M.Map String Type
type StructEnv = M.Map String [(String, Type)]
type FuncEnv = M.Map String FuncSig
type BlockStack = [String]
type Env = (VarEnv, FuncEnv, StructEnv, BlockStack)
type SemCheck a = StateT Env (Except SemanticError) a

analyze :: Program -> Either SemanticError Program
analyze (Program tops) = runExcept $ evalStateT (checkProgram tops) initialEnv
  where
    initialEnv = (M.empty, initialFuncs, M.empty, [])
    initialFuncs = M.fromList
      [ ("Vec2", FuncSig [TypeNum Float32, TypeNum Float32] (TypeVec (Vec2 Float32)))
      , ("Vec3", FuncSig [TypeNum Float32, TypeNum Float32, TypeNum Float32] (TypeVec (Vec3 Float32)))
      , ("Vec4", FuncSig [TypeNum Float32, TypeNum Float32, TypeNum Float32, TypeNum Float32] (TypeVec (Vec4 Float32)))
      , ("print", FuncSig [TypeAny] TypeVoid)
      ]

checkProgram :: [TopLevel] -> SemCheck Program
checkProgram tops = do
    -- First pass - collect declarations
    mapM_ collectDeclarations tops

    -- Get initial environment
    (vars, funs, structs, blocks) <- get

    -- Process each top level expression sequentially while accumulating bindings
    processedTops <- foldM (\acc top -> do
        top' <- checkTopLevel top  -- Now returns TopLevel
        -- Get the updated environment with any new bindings
        (newVars, currFuns, currStructs, currBlocks) <- get
        -- Restore accumulated bindings for next expression
        put (newVars, currFuns, currStructs, currBlocks)
        return $ acc ++ [top']
      ) [] tops

    return $ Program processedTops

-- Here we collect function and struct declarations before checking the rest
collectDeclarations :: TopLevel -> SemCheck ()
collectDeclarations (TLDecl (DFunc name params retType _)) = do
    (vars, funs, structs, blocks) <- get
    let ptypes = [t | Param _ t <- params]
    when (M.member name funs) $
        throwError $ RecursionInGlobalScope name
    put (vars, M.insert name (FuncSig ptypes retType) funs, structs, blocks)
collectDeclarations (TLDecl (DStruct name fields)) = do
    (vars, funs, structs, blocks) <- get
    put (vars, funs, M.insert name fields structs, blocks)
collectDeclarations (TLType name typ) = do
    -- For a type declaration, if it's a struct, we store it in the environment
    (vars, funs, structs, blocks) <- get
    case typ of
        TypeStruct sName fields -> do
            when (sName /= name) $
                throwError $ TypeMismatch (TypeStruct name []) typ
            forM_ fields $ \(_, fieldType) -> checkTypeExists fieldType
            -- Add constructor function for the struct
            let paramTypes = map snd fields
            let funcSig = FuncSig paramTypes (TypeStruct name fields)
            traceM $ "Registered constructor for " ++ name ++ " with signature: " ++ show funcSig
            put (vars, M.insert name funcSig funs, M.insert name fields structs, blocks)
        _ -> throwError $ TypeMismatch (TypeStruct name []) typ
collectDeclarations _ = return ()

checkTopLevel :: TopLevel -> SemCheck TopLevel
checkTopLevel (TLExpr (Block scope@(BlockScope label exprs result)))
  | label == "top_let" = do
    -- For top-level let blocks, process expressions while preserving environment
    mapM_ inferTypeExpr exprs
    -- Explicit environment preservation not needed - bindings from inferTypeExpr persist
    return $ TLExpr (Block scope)

checkTopLevel (TLExpr e) = do
    inferTypeExpr e
    return $ TLExpr e

checkTopLevel (TLDecl d) = do
    checkDecl d
    return $ TLDecl d

checkTopLevel tl@(TLType _ _) = return tl

checkDecl :: Decl -> SemCheck ()
checkDecl (DFunc name params retType body) = do
    (vars, funs, structs, blocks) <- get
    let paramMap = M.fromList [(n, t) | Param n t <- params]
    put (M.union paramMap vars, funs, structs, blocks)
    bodyType <- inferTypeExpr body
    when (bodyType /= retType) $
        throwError $ TypeMismatchInFunction name retType bodyType
    put (vars, funs, structs, blocks)
checkDecl (DStruct _ _) = return ()

inferTypeExpr :: Expr -> SemCheck Type
inferTypeExpr expr = do
  traceM $ "Inferring type of expression: " ++ show expr

  (vars, _, _, _) <- get
  traceM $ "Current variable environment: " ++ show vars
 
  result <- case expr of
        StrLit s ->
          if null s
          then throwError EmptyStringLiteral
          else return TypeString

        NumLit numType _ -> return $ TypeNum numType

        Var name -> do
            traceM $ "Looking up variable: " ++ name
            (vars, _, _, _) <- get
            traceM $ "Looking up in environment: " ++ show vars
            case M.lookup name vars of
                Nothing -> do
                    traceM $ "ERROR: Undefined variable: " ++ name
                    throwError $ UndefinedVariable name
                Just t -> do
                    traceM $ "Found variable type: " ++ show t
                    return t

        Call "print" [arg] -> do
            -- For print, we don't care about the argument type
            _ <- inferTypeExpr arg
            return TypeVoid

        Call name args -> do
          traceM $ "Inferring Call: " ++ name ++ " with " ++ show (length args) ++ " args"
          argTypes <- mapM inferTypeExpr args
          traceM $ "Call arg types: " ++ show argTypes
          (_, funcEnv, structEnv, _) <- get
          traceM $ "Function environment: " ++ show funcEnv
          traceM $ "Struct environment: " ++ show funcEnv
          traceM $ "Looking up function: " ++ name
          case M.lookup name funcEnv of
              Just (FuncSig paramTypes retType) -> do
                  when (length args /= length paramTypes) $
                      throwError $ ArgumentCountMismatch name (length paramTypes) (length args)
                  argTypes <- mapM inferTypeExpr args
                  zipWithM_ (\expected actual ->
                      unless (expected == actual) $
                          throwError $ TypeMismatchInFunction name expected actual)
                      paramTypes argTypes
                  return retType
              Nothing ->
                  case M.lookup name structEnv of
                      Just fields -> do
                          when (length args /= length fields) $
                              throwError $ ArgumentCountMismatch name (length fields) (length args)
                          argTypes <- mapM inferTypeExpr args
                          zipWithM_ (\(_, fieldType) argType -> do
                              unless (fieldType == argType) $
                                  throwError $ TypeMismatch fieldType argType)
                              fields argTypes
                          return $ TypeStruct name fields
                      Nothing -> throwError $ UndefinedFunction name

        BinOp op e1 e2 -> do
            t1 <- inferTypeExpr e1
            t2 <- inferTypeExpr e2
            traceM $ "BinOp " ++ show op ++ " types: " ++ show t1 ++ " and " ++ show t2
            case (op, t1, t2) of
                (Add, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
                (Sub, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
                (Mul, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
                (Div, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
                (Lt, TypeNum n1, TypeNum n2) | n1 == n2 -> return TypeBool
                (Gt, TypeNum n1, TypeNum n2) | n1 == n2 -> return TypeBool
                (Eq, TypeNum n1, TypeNum n2) | n1 == n2 -> return TypeBool
                (Add, TypeVec v1, TypeVec v2) | v1 == v2 -> return $ TypeVec v1
                (Dot, TypeVec v1, TypeVec v2) | v1 == v2 ->
                    case v1 of
                        Vec2 nt -> return $ TypeNum nt
                        Vec3 nt -> return $ TypeNum nt
                        Vec4 nt -> return $ TypeNum nt
                _ -> throwError $ TypeMismatchInOp op t1 t2

        FieldAccess expr field -> do
            exprType <- inferTypeExpr expr
            case exprType of
                TypeVec vecType -> case (vecType, field) of
                    (Vec2 nt, "x") -> return $ TypeNum nt
                    (Vec2 nt, "y") -> return $ TypeNum nt
                    (Vec3 nt, "x") -> return $ TypeNum nt
                    (Vec3 nt, "y") -> return $ TypeNum nt
                    (Vec3 nt, "z") -> return $ TypeNum nt
                    (Vec4 nt, "x") -> return $ TypeNum nt
                    (Vec4 nt, "y") -> return $ TypeNum nt
                    (Vec4 nt, "z") -> return $ TypeNum nt
                    (Vec4 nt, "w") -> return $ TypeNum nt
                    _ -> throwError $ UndefinedField (show vecType) field
                TypeStruct structName fields ->
                    case lookup field fields of
                        Just fieldType -> return fieldType
                        Nothing -> throwError $ UndefinedField structName field
                _ -> throwError $ UndefinedField (show exprType) field

        VecLit vecType components -> do
            componentTypes <- mapM inferTypeExpr components
            let expectedCount = case vecType of
                    Vec2 _ -> 2
                    Vec3 _ -> 3
                    Vec4 _ -> 4
            when (length components /= expectedCount) $
                throwError $ InvalidVectorComponents vecType componentTypes

            let expectedType = TypeNum $ case vecType of
                    Vec2 t -> t
                    Vec3 t -> t
                    Vec4 t -> t

            forM_ componentTypes $ \compType ->
                unless (compType == expectedType) $
                    throwError $ InvalidVectorComponents vecType componentTypes

            return $ TypeVec vecType

        StructLit "Vec3" fields -> do
            -- Special case for Vec3
            when (length fields /= 3) $
                throwError $ ArgumentCountMismatch "Vec3" 3 (length fields)
            fieldTypes <- mapM (inferTypeExpr . snd) fields
            forM_ fieldTypes $ \ft -> unless (isNumericType ft) $
                throwError $ TypeMismatch (TypeNum Float32) ft
            return $ TypeVec (Vec3 Float32)

        Let name expr -> do
            exprType <- inferTypeExpr expr
            (vars, funs, structs, blocks) <- get
            put (M.insert name exprType vars, funs, structs, blocks)
            return exprType

        BoolLit _ -> return TypeBool

        Block scope -> do
            -- Save current environment
            (oldVars, funs, structs, blocks) <- get
            -- Process block expressions
            types <- mapM inferTypeExpr (blockExprs scope)
            -- Get updated environment with block's variables
            (blockVars, _, _, _) <- get
            -- Determine block type
            case (blockExprs scope, blockResult scope) of
                ([], Nothing) -> do
                    traceM "Empty block, defaulting to Int32"
                    put (oldVars, funs, structs, blocks)
                    return $ TypeNum Int32
                (exprs, Nothing) -> do
                    let lastType = last types
                    traceM $ "Block type from last expression: " ++ show lastType
                    put (oldVars, funs, structs, blocks)
                    return lastType
                (_, Just result) -> do
                    -- Use block's variables when analyzing result
                    put (blockVars, funs, structs, blocks)
                    resultType <- inferTypeExpr result
                    -- Restore original environment after
                    put (oldVars, funs, structs, blocks)
                    return resultType

        StructLit name fields -> do
            (_, _, structs, _) <- get
            case M.lookup name structs of
                Nothing -> throwError $ UndefinedStruct name
                Just structFields -> do
                    when (length fields /= length structFields) $
                        throwError $ ArgumentCountMismatch name (length structFields) (length fields)
                    forM_ (zip fields structFields) $ \((fName, fieldExpr), (expectedName, expectedType)) -> do
                        when (fName /= expectedName) $
                            throwError $ UndefinedField name fName
                        actualType <- inferTypeExpr fieldExpr
                        when (actualType /= expectedType) $
                            throwError $ TypeMismatch expectedType actualType
                    return $ TypeStruct name structFields

        AssignOp name op rhs -> do
                -- Look up variable type
                (vars, _, _, _) <- get
                case M.lookup name vars of
                    Just varType -> do
                        -- Verify right hand side matches variable type
                        rhsType <- inferTypeExpr rhs
                        if varType == rhsType
                            then return varType
                            else throwError $ TypeMismatch rhsType varType
                    Nothing -> throwError $ UndefinedVariable name

        VarDecl name val -> do
            traceM $ "Inferring VarDecl for " ++ name
            valType <- inferTypeExpr val
            traceM $ "VarDecl value type: " ++ show valType
            -- Check if variable was actually added
            addVar name valType
            (vars, _, _, _) <- get
            traceM $ "Environment after VarDecl: " ++ show vars
            return valType

        Assign name val -> do
            (vars, _, _, _) <- get
            case M.lookup name vars of
                Nothing -> throwError $ UndefinedVariable name
                Just expectedType -> do
                    valType <- inferTypeExpr val
                    unless (valType == expectedType) $
                        throwError $ TypeMismatch expectedType valType
                    return expectedType

        While cond body -> do
            traceM "Inferring While expression"
            -- Check condition evaluates to bool
            condType <- inferTypeExpr cond
            traceM $ "While condition type: " ++ show condType
            case condType of
                TypeBool -> do
                    -- While expression returns void
                    traceM "Valid bool condition, inferring body type"
                    _ <- inferTypeExpr body
                    return TypeVoid
                _ -> do
                    traceM $ "Invalid condition type: " ++ show condType
                    throwError $ TypeMismatch TypeBool condType

        _ -> throwError $ IncompatibleTypes "Unsupported expression" TypeBool TypeBool

  traceM $ "Final type for expression: " ++ show expr ++ " is " ++ show result
  return result

inferTypeExpr (StructLit "Vec3" fields) = do
  -- Check fields
  let expectedFields = ["x","y","z"]
  when (map fst fields /= expectedFields) $
    throwError $ ArgumentCountMismatch "Vec3" (length expectedFields) (length fields)
  fieldTypes <- mapM (inferTypeExpr . snd) fields
  forM_ fieldTypes $ \ft -> unless (ft == TypeNum Float32) $
    throwError $ TypeMismatch (TypeNum Float32) ft
  return (TypeVec (Vec3 Float32))

addVar :: String -> Type -> SemCheck Type
addVar name typ = do
    traceM $ "Adding variable to environment: " ++ name ++ " : " ++ show typ
    (vars, funs, structs, blocks) <- get
    traceM $ "Current var environment: " ++ show vars
    put (M.insert name typ vars, funs, structs, blocks)
    traceM $ "Updated var environment: " ++ show (M.insert name typ vars)
    return typ

checkBinOp :: Op -> Type -> Type -> SemCheck Type
checkBinOp op t1 t2 = case (op, t1, t2) of
    (Add, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
    (Sub, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
    (Mul, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
    (Div, TypeNum n1, TypeNum n2) | n1 == n2 -> return $ TypeNum n1
    (Dot, TypeVec v1, TypeVec v2) | v1 == v2 -> return $ TypeNum (getVecNumType v1)
    (Add, TypeVec v1, TypeVec v2) | v1 == v2 -> return $ TypeVec v1
    _ -> throwError $ TypeMismatchInOp op t1 t2

inferVecFieldAccess :: VecType -> String -> SemCheck Type
inferVecFieldAccess vecType field = case (vecType, field) of
    (Vec2 nt, "x") -> return $ TypeNum nt
    (Vec2 nt, "y") -> return $ TypeNum nt
    (Vec3 nt, "x") -> return $ TypeNum nt
    (Vec3 nt, "y") -> return $ TypeNum nt
    (Vec3 nt, "z") -> return $ TypeNum nt
    (Vec4 nt, "x") -> return $ TypeNum nt
    (Vec4 nt, "y") -> return $ TypeNum nt
    (Vec4 nt, "z") -> return $ TypeNum nt
    (Vec4 nt, "w") -> return $ TypeNum nt
    _ -> throwError $ UndefinedField (show vecType) field

checkTypeExists :: Type -> SemCheck ()
checkTypeExists typ = case typ of
    TypeVec vt -> return ()  -- Vector types are built-in
    TypeStruct name fields -> do
        (_, _, structs, _) <- get
        unless (M.member name structs) $
            throwError $ UndefinedStruct name
        forM_ fields $ \(_, fieldType) -> checkTypeExists fieldType
    _ -> return ()

getVecNumType :: VecType -> NumType
getVecNumType (Vec2 nt) = nt
getVecNumType (Vec3 nt) = nt
getVecNumType (Vec4 nt) = nt

isNumericType :: Type -> Bool
isNumericType (TypeNum _) = True
isNumericType _ = False
