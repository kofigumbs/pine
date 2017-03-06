{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Generate.ErlangCore.Builder
  ( Expr(..), Clause(..)
  , Function(..)
  , functionsToText
  )
  where

import Prelude hiding (break)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.ByteString (ByteString)
import Data.Text.Lazy.Builder
import Data.Text.Lazy.Builder.Int (decimal)
import Data.Text.Lazy.Builder.RealFloat (formatRealFloat, FPFormat(..))
import qualified Data.Text.Lazy as LazyText
import qualified Data.ByteString as ByteString
import qualified Data.List as List
import qualified Data.Char as Char



-- EXPRESSIONS


data Expr
  = Int Int
  | Chr Char
  | Float Double
  | Atom Text
  | Var Text
  | Anything
  | Apply Expr [Expr]
  | Call Text Text [Expr]
  | Tuple [Expr]
  | List [Expr]
  | BitString ByteString
  | Case Expr [Clause]
  | Fun [Text] Expr
  | FunctionRef Text Int


data Clause =
  Clause
    { _pattern :: Expr
    , _guard :: Expr
    , _body :: Expr
    }



-- TOP LEVEL


data Function
  = Function Text [Text] Expr -- 'f'/0 = fun () -> ...


functionsToText :: [Function] -> LazyText.Text
functionsToText functions =
  toLazyText (mconcat (map fromFunction functions))


fromFunction :: Function -> Builder
fromFunction function =
  case function of
    Function name args body ->
      fromFunctionName name (length args) <> " = "
      <> fromFun args break (fromExpr body) <> "\n"



-- EXPRESSIONS


fromExpr :: Expr -> Builder
fromExpr expression =
  case expression of
    Int n ->
      decimal n

    Chr c ->
      decimal (Char.ord c)

    Float n ->
      formatRealFloat Exponent (Just 20) n

    Atom name ->
      quoted name

    Var name ->
      safeVar name

    Anything ->
      "_"

    Apply function args ->
      "apply " <> fromExpr function <> " ("
      <> commaSep fromExpr args
      <> ")"

    Call moduleName functionName args ->
      "call " <> quoted moduleName <> ":" <> quoted functionName <> " ("
      <> commaSep fromExpr args
      <> ")"

    Tuple exprs ->
      "{" <> commaSep fromExpr exprs <> "}"

    List exprs ->
      "[" <> commaSep fromExpr exprs <> "]"

    BitString str ->
      let
        collectWord c rest =
          "#<" <> fromString (show c)
          <> ">(8,1,'integer',['unsigned'|['big']])" : rest
      in
        "#{" <> commaSep id (ByteString.foldr collectWord [] str) <> "}#"

    Case expr clauses ->
      let
        clause (Clause pattern guard body) =
          break <> "<" <> fromExpr pattern <> "> when " <> fromExpr guard
          <> " -> " <> fromExpr body
      in
        "case " <> fromExpr expr <> " of" <> mconcat (map clause clauses)

    Fun args body ->
      fromFun args " " (fromExpr body)

    FunctionRef name airity ->
      fromFunctionName name airity


fromFunctionName :: Text -> Int -> Builder
fromFunctionName name airity =
  quoted name <> "/" <> decimal airity


fromFun :: [Text] -> Builder -> Builder -> Builder
fromFun args separator body =
  "fun (" <> commaSep safeVar args <> ") ->" <> separator <> body



-- HELPERS


commaSep :: (a -> Builder) -> [a] -> Builder
commaSep toBuilder as =
  mconcat (List.intersperse ", " (map toBuilder as))


safeVar :: Text -> Builder
safeVar name =
  "_" <> fromText name


quoted :: Text -> Builder
quoted str =
  "'" <> fromText str <> "'"


break :: Builder
break =
  "\n\t"
