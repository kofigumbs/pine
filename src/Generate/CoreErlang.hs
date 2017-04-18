{-# LANGUAGE OverloadedStrings #-}
module Generate.CoreErlang (generate) where

import Control.Monad (liftM2)

import qualified Data.ByteString.Builder as BS
import qualified Data.Text as Text
import Data.Text (Text)

import qualified AST.Module as Module
import qualified AST.Module.Name as ModuleName
import qualified AST.Variable as Var
import qualified AST.Expression.Optimized as Opt
import Elm.Compiler.Module (qualifiedVar)

import qualified Generate.CoreErlang.Builder as Core
import qualified Generate.CoreErlang.BuiltIn as BuiltIn
import qualified Generate.CoreErlang.Environment as Env
import qualified Generate.CoreErlang.Literal as Literal
import qualified Generate.CoreErlang.Substitution as Subst
import qualified Generate.CoreErlang.Pattern as Pattern


generate
  :: Module.Interfaces
  -> Module.Module (Module.Info [Opt.Def])
  -> BS.Builder
generate interfaces (Module.Module moduleName _ info) =
  Core.encodeUtf8 $
    map (Env.run interfaces . generateDef moduleName) (Module.program info)


generateDef :: ModuleName.Canonical -> Opt.Def -> Env.Gen Core.Function
generateDef moduleName def =
  let
    function name =
      Core.Function (qualifiedVar moduleName name)
  in
    case def of
      Opt.Def _ name (Opt.Function args body) ->
        function name args <$> generateExpr body

      Opt.Def _ name body ->
        function name [] <$> generateExpr body

      Opt.TailDef _ name args body ->
        do  body' <-
              generateExpr body

            let letRec =
                  Core.LetRec name args body'
                    $ Core.Apply (Core.LFunction name (length args))
                    $ map (Core.LTerm . Core.Var) args

            return $ function name args letRec


generateExpr :: Opt.Expr -> Env.Gen Core.Expr
generateExpr opt =
  case opt of
    Opt.Literal lit ->
      return $ Core.Lit (Core.LTerm (Literal.term lit))

    Opt.Var var ->
      generateVar var

    Opt.List exprs ->
      Pattern.list =<< mapM generateExpr exprs

    Opt.Binop var lhs rhs ->
      generateBinop var =<< mapM generateExpr [lhs, rhs]

    Opt.Function args body ->
      Core.Fun args <$> generateExpr body

    Opt.Call function args ->
      generateCall function =<< mapM generateExpr args

    Opt.TailCall name _ args ->
      let
        function =
          Core.LFunction name (length args)
      in
        Subst.many (Core.Apply function) =<< mapM generateExpr args

    Opt.If branches finally ->
      let
        toBranch bool expr =
          (Core.PTerm (Core.Atom bool), expr)

        toCase (condition, ifTrue) ifFalse =
          do  checks <-
                sequence
                  [ toBranch "true" <$> generateExpr ifTrue
                  , toBranch "false" <$> ifFalse
                  ]

              Subst.one (flip Core.Case checks) =<< generateExpr condition
      in
        foldr toCase (generateExpr finally) branches

    Opt.Let defs expr ->
      generateLet defs (generateExpr expr)

    Opt.Case switch branches ->
      do  let toCore (pattern, expr) =
                liftM2 (,) (Pattern.match pattern) (generateExpr expr)

          branches' <-
            mapM toCore branches

          Subst.one (flip Core.Case branches') =<< generateExpr switch

    Opt.Ctor name exprs ->
      Pattern.ctor name =<< mapM generateExpr exprs

    Opt.CtorAccess expr index ->
      Pattern.ctorAccess index =<< generateExpr expr

    Opt.Access record field ->
      Subst.one (BuiltIn.get field) =<< generateExpr record

    Opt.Update record fields ->
      do  let zipper m entries =
                Core.Update (zip (generateKeys fields) entries) m

          record' <-
            generateExpr record

          Subst.many1 zipper record' =<< mapM (generateExpr . snd) fields

    Opt.Record fields ->
      do  values <-
            mapM (generateExpr . snd) fields

          Subst.many (Core.Map . zip (generateKeys fields)) values

    Opt.Cmd moduleName ->
      return $ BuiltIn.effect moduleName

    Opt.Sub moduleName ->
      return $ BuiltIn.effect moduleName

    Opt.OutgoingPort _name _type ->
      error
        "TODO: Opt.OutgoingPort to Core.Expr"

    Opt.IncomingPort _name _type ->
      error
        "TODO: Opt.IncomingPort to Core.Expr"

    Opt.Program _type expr ->
      -- TODO: use the type to decode argument
      generateExpr expr

    Opt.GLShader _ _ _ ->
      -- TODO: remove this from the AST
      error
        "Shaders can't be used with the BEAM compiler!"

    Opt.Crash _moduleName _region _maybeExpr ->
      error
        "TODO: Opt.Crash to Core.Expr"



--- VARIABLES


generateVar :: Var.Canonical -> Env.Gen Core.Expr
generateVar (Var.Canonical home name) =
  case home of
    Var.Local ->
      maybe
        (Core.Lit (Core.LTerm (Core.Var name)))
        (Core.Lit . Core.LFunction name)
        <$> Env.getLocalArity name

    Var.Module moduleName ->
      generateRef moduleName name

    Var.TopLevel moduleName ->
      generateRef moduleName name

    Var.BuiltIn ->
      error
        "Will go away when merged with upstream dev."


generateCall :: Opt.Expr -> [Core.Expr] -> Env.Gen Core.Expr
generateCall function args =
  case function of
    Opt.Var (Var.Canonical (Var.Module moduleName) name)
      | ModuleName.canonicalIsNative moduleName ->
      generateNative moduleName name args

    _ ->
      do  function' <-
            generateExpr function

          case function' of
            Core.Lit f@(Core.LFunction _ arity)
              | arity == length args ->
              Subst.many (Core.Apply f) args

            _ ->
              Subst.many1 BuiltIn.apply function' args


generateRef :: ModuleName.Canonical -> Text -> Env.Gen Core.Expr
generateRef moduleName name =
  if ModuleName.canonicalIsNative moduleName then
    generateNative moduleName name []

  else
    do  arity <-
          Env.getGlobalArity moduleName name

        let function =
              Core.LFunction (qualifiedVar moduleName name) arity

        if arity == 0
          then return $ Core.Apply function []
          else return $ Core.Lit function


generateNative
  :: ModuleName.Canonical
  -> Text
  -> [Core.Expr]
  -> Env.Gen Core.Expr
generateNative (ModuleName.Canonical _ rawModule) name =
  Subst.many (Core.Call (Text.drop 7 rawModule) name)


generateLet :: [Opt.Def] -> Env.Gen Core.Expr -> Env.Gen Core.Expr
generateLet defs body =
  foldr collectLets body defs

  where
    collectLets def state =
      defToLet def <*> state

    defToLet def =
      case def of
        Opt.TailDef _ name args body ->
          Env.withLocalArity name (length args)
            $ Core.LetRec name args <$> generateExpr body

        Opt.Def _ name (Opt.Function args body) ->
          Env.withLocalArity name (length args)
            $ Core.LetRec name args <$> generateExpr body

        Opt.Def _ name body ->
          Core.Let name <$> generateExpr body


generateBinop :: Var.Canonical -> [Core.Expr] -> Env.Gen Core.Expr
generateBinop (Var.Canonical home name) =
  Subst.many (Core.Apply (Core.LFunction qualified 2))

  where
    qualified =
      case home of
        Var.Local -> error "Will go away when merged with upstream dev"
        Var.Module moduleName -> qualifiedVar moduleName name
        Var.TopLevel moduleName -> qualifiedVar moduleName name
        Var.BuiltIn -> error "Will go away when merged with upstream dev"



-- RECORDS


generateKeys :: [(Text, a)] -> [Core.Literal]
generateKeys =
  map (Core.LTerm . Core.Atom . fst)
