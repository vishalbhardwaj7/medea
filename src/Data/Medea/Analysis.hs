{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}

module Data.Medea.Analysis where

import Prelude
import Algebra.Graph.Acyclic.AdjacencyMap (AdjacencyMap, toAcyclic)
import qualified Algebra.Graph.AdjacencyMap as Cyclic
import Control.Monad (foldM, when)
import Control.Monad.Except (MonadError (..))
import Control.Monad.State.Class (MonadState)
import Control.Monad.State.Strict (evalStateT, gets, modify)
import Data.Bool (bool)
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as M
import Data.Medea.JSONType (JSONType (..))
import Data.Medea.Parser.Primitive
  ( Identifier,
    PrimTypeIdentifier (..),
    MedeaString,
    Natural,
    isReserved,
    isStartIdent,
    startIdentifier,
    tryPrimType,
    typeOf,
  )
import qualified Data.Medea.Parser.Spec.Schema as Schema
import qualified Data.Medea.Parser.Spec.Schemata as Schemata
import qualified Data.Medea.Parser.Spec.Type as Type
import Data.Medea.Parser.Spec.Array (minLength, maxLength)
import Data.Medea.Parser.Spec.Object (properties)
import Data.Medea.Parser.Spec.Property (propSchema, propName, propOptional)
import qualified Data.Set as S
import qualified Data.Vector as V

data AnalysisError
  = DuplicateSchemaName Identifier
  | NoStartSchema
  | DanglingTypeReference Identifier
  | TypeRelationIsCyclic
  | ReservedDefined Identifier
  | UnreachableSchemata
  | MinMoreThanMax Identifier
  | DanglingTypeRefProp Identifier
  | DuplicatePropName Identifier MedeaString

data TypeNode
  = PrimitiveNode JSONType
  | AnyNode
  | CustomNode Identifier
  deriving (Eq, Ord, Show)

data ReducedSchema = ReducedSchema ReducedTypeSpec ReducedArraySpec ReducedObjectSpec
  deriving (Show)
type ReducedTypeSpec = V.Vector TypeNode
type ReducedArraySpec = (Maybe Natural, Maybe Natural)
type ReducedObjectSpec = M.Map MedeaString (TypeNode, Bool)

intoAcyclic ::
  (MonadError AnalysisError m) =>
  [(TypeNode, TypeNode)] ->
  m (AdjacencyMap TypeNode)
intoAcyclic = maybe (throwError TypeRelationIsCyclic) pure . toAcyclic . Cyclic.edges

intoEdges ::
  (MonadError AnalysisError m) =>
  M.Map Identifier ReducedSchema ->
  ReducedSchema ->
  m [(TypeNode, TypeNode)]
intoEdges m scm@(ReducedSchema typeNodes lenRange redObjSpec) =
  evalStateT (go [] scm startNode <* checkUnusedSchema <* checkUndefinedPropSchema) S.empty
  where
    startNode = CustomNode startIdentifier
    checkUnusedSchema = do
      reachableSchemas <- gets S.size 
      when (reachableSchemas < M.size m) $ throwError UnreachableSchemata
    checkUndefinedPropSchema =
      case filter isUndefinedNode . map fst . M.elems $ redObjSpec of
        (CustomNode ident):_ -> throwError $ DanglingTypeRefProp ident
        _ -> pure ()
      where
        isUndefinedNode (CustomNode ident) = isNothing . M.lookup ident $ m
        isUndefinedNode _                  = False
    go acc scm node = do
      alreadySeen <- gets (S.member node)
      if alreadySeen
      then pure acc
      else do
        modify (S.insert node)
        traverseRefs acc node $ V.toList typeNodes
    traverseRefs acc node [] = pure $ (node, AnyNode) : acc
    traverseRefs acc node refs =
      (acc <>) . concat <$> traverse (resolveLinks node) refs
    -- NOTE: t can not be AnyNode
    resolveLinks u t = case t of
      PrimitiveNode _  -> pure . pure $ (u,t)
      CustomNode ident -> case M.lookup ident m of
        Nothing -> throwError . DanglingTypeReference $ ident
        Just scm -> (:) <$> pure (u, t) <*> go [] scm t
      AnyNode -> error "Unexpected type node"

intoMap ::
  (MonadError AnalysisError m) =>
  Schemata.Specification ->
  m (M.Map Identifier ReducedSchema)
intoMap (Schemata.Specification v) = foldM go M.empty v
  where
    go acc spec = M.alterF (checkedInsert spec) (Schema.name spec) acc
    checkedInsert spec = \case
      Nothing -> do
        when (isReserved ident && (not . isStartIdent) ident)
          $ throwError . ReservedDefined
          $ ident
        Just <$> reduceSchema spec
      Just _ -> throwError . DuplicateSchemaName $ ident
      where
        ident = Schema.name spec

reduceSchema ::
  (MonadError AnalysisError m) =>
  Schema.Specification ->
  m ReducedSchema
reduceSchema scm@(Schema.Specification ident (Type.Specification types) arraySpec objSpec) = do
  let reducedArraySpec = (minLength arraySpec, maxLength arraySpec)
      typeNodes = fmap (identToNode . Just) types
  reducedObjSpec <- foldM go M.empty (properties objSpec)
  when (uncurry (>) reducedArraySpec) $
    throwError $ MinMoreThanMax ident
  pure $ ReducedSchema typeNodes reducedArraySpec reducedObjSpec
    where
      go acc prop = M.alterF (checkedInsert prop) (propName prop) acc
      checkedInsert prop = \case
        Nothing -> pure . Just $ (identToNode (propSchema prop), propOptional prop)
        Just _  -> throwError $ DuplicatePropName ident (propName prop)
      toMap = M.fromList . fmap reduceProp
      reduceProp prop = (propName prop,
                           (identToNode (propSchema prop), propOptional prop))

identToNode :: Maybe Identifier -> TypeNode
identToNode ident = case ident of
  Nothing -> AnyNode
  Just t -> maybe (CustomNode t) (PrimitiveNode . typeOf) $ tryPrimType t

checkStartSchema ::
  (MonadError AnalysisError m) =>
  M.Map Identifier ReducedSchema ->
  m ReducedSchema
checkStartSchema m = case M.lookup startIdentifier m of
  Nothing -> throwError NoStartSchema
  Just scm -> pure scm
