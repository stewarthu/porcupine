{-# LANGUAGE Arrows                     #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# OPTIONS_GHC -Wall #-}

-- | This module provides some utilities for when the pipeline needs to access
-- several files organized in layers for each location in the 'LocationTree'
module System.TaskPipeline.VirtualFileAccess
  ( -- * Reexports
    Typeable

    -- * High-level API
  , loadData
  , loadDataStream
  , writeData
  , writeDataStream

    -- * Lower-level API
  , accessVirtualFile
  , withVFileAccessFunction
  , withFolderAccessNodes
  , getLocsMappedTo
  , streamHeadTask
  ) where

import           Prelude                            hiding (id, (.))

import           Control.Lens
import           Control.Monad                      (forM)
import qualified Data.Foldable                      as F
import qualified Data.HashMap.Strict                as HM
import           Data.Locations
import           Data.Maybe                         (maybe)
import           Data.Monoid
import           Data.Representable
import qualified Data.Text                          as T
import           Data.Typeable
import           Streaming                          (Of (..), Stream)
import qualified Streaming.Prelude                  as S
import           System.TaskPipeline.PTask
import           System.TaskPipeline.PTask.Internal
import           System.TaskPipeline.ResourceTree


streamHeadTask :: (KatipContext m) => PTask m (Stream (Of (i, a)) m r) a
streamHeadTask = unsafeLiftToPTask $ \s ->
  maybe (error $ "streamHeadTask: No value in the output stream") snd <$> S.head_ s

-- | Uses only the read part of a 'VirtualFile'. It is therefore considered as a
-- pure 'DataSource'. For practical reasons the task input is () rather than
-- Void.
loadData
  :: (LocationMonad m, KatipContext m, Typeable a)
  => VirtualFile ignored a -- ^ A 'DataSource'
  -> PTask m () a  -- ^ The resulting task
loadData vf = arr (\_ -> S.yield ([] :: [Int]))
          >>> loadDataStream [] vf
          >>> streamHeadTask

-- | Loads a stream of repeated occurences of a VirtualFile, from a stream of
-- indices. The process is lazy: the data will actually be read when the
-- resulting stream is consumed.
loadDataStream :: (Show idx, LocationMonad m, KatipContext m, Typeable a)
               => [LocVariable]
               -> VirtualFile ignored a -- ^ A 'DataSource'
               -> PTask m (Stream (Of [idx]) m r) (Stream (Of ([idx], a)) m r)
loadDataStream repIndices vf =
      arr (S.map (, error "loadDataStream: THIS IS VOID"))
  >>> accessVirtualFile repIndices (makeSource vf)

-- | Uses only the write part of a 'VirtualFile'. It is therefore considered as
-- a pure 'DataSink'.
writeData
  :: (LocationMonad m, KatipContext m, Typeable a)
  => VirtualFile a ignored  -- ^ A 'DataSink'
  -> PTask m a ()
writeData vf = arr (\a -> S.yield ([] :: [Int], a))
           >>> writeDataStream [] vf

-- | The simplest way to consume a stream of data inside a pipeline. Just write
-- it to repeated occurences of a VirtualFile. See
-- System.TaskPipeline.Repetition.Fold for more complex ways to consume a
-- Stream.
writeDataStream :: (Show idx, LocationMonad m, KatipContext m, Typeable a)
                => [LocVariable]
                -> VirtualFile a ignored -- ^ A 'DataSink'
                -> PTask m (Stream (Of ([idx], a)) m r) r
writeDataStream repIndices vf =
  accessVirtualFile repIndices (makeSink vf) >>> unsafeLiftToPTask S.effects

-- | When building the pipeline, stores into the location tree the way to read
-- or write the required resource. When running the pipeline, access the
-- instances of this ressource corresponding to the values of some repetition
-- indices.
accessVirtualFile
  :: forall m a b idx r.
     (LocationMonad m, KatipContext m, Typeable a, Typeable b, Show idx)
  => [LocVariable]  -- ^ The list of repetition indices. Can be empty if the
                    -- file isn't meant to be repeated
  -> VirtualFile a b  -- ^ The VirtualFile to access
  -> PTask m (Stream (Of ([idx], a)) m r)
             (Stream (Of ([idx], b)) m r)  -- ^ The resulting task reads a
                                           -- stream of indices and input values
                                           -- and returns a stream of the same
                                           -- indices associated to their
                                           -- outputs.
accessVirtualFile repIndices vfile =
  withVFileAccessFunction vfile' $ \accessFn inputStream ->
    return $ S.mapM (runOnce accessFn) inputStream
  where
    runOnce :: (LocVariableMap -> DataAccessor m a b) -> ([idx], a) -> m ([idx], b)
    runOnce accessFn (ixVals, input) = do
      daPerformWrite da input
      (ixVals,) <$> daPerformRead da
      where
        da = accessFn lvMap
        lvMap = HM.fromList $ zip repIndices $ map show ixVals
    vfile' = case repIndices of
      [] -> vfile
      _  -> vfile & over (vfileSerials.serialsRepetitionKeys) (repIndices++)

-- | Executes as a task a function that needs to access the content of the
-- DataAccessNode of a VirtualFile.
withVFileAccessFunction
  :: forall m i o a b.
     (MonadThrow m, KatipContext m, Typeable a, Typeable b)
  => VirtualFile a b  -- ^ The VirtualFile to access
  -> ((LocVariableMap -> DataAccessor m a b) -> i -> m o)
         -- ^ The action to run. It will be a function to access the
         -- VirtualFile. The LocVariableMap can just be empty if the VirtualFile
         -- isn't meant to be repeated
  -> PTask m i o
withVFileAccessFunction vfile f =
  withFolderAccessNodes path (Identity fname) $
    \(Identity n) input -> case n of
      DataAccessNode _ (action :: LocVariableMap -> DataAccessor m a' b') ->
        case (eqT :: Maybe (a :~: a'), eqT :: Maybe (b :~: b')) of
          (Just Refl, Just Refl)
            -> f action input
          _ -> err "input or output types don't match"
      _ -> err "no access action is present in the tree"
  where
    path = init $ vfile ^. vfilePath
    fname = file (last $ vfile ^. vfilePath) $ VirtualFileNode vfile
    err s = throwWithPrefix $
      "withVFileAccessFunction (" ++ showVFilePath vfile ++ "): " ++ s

-- | Wraps in a task a function that needs to access some items present in a
-- subfolder of the 'LocationTree' and mark these accesses as done.
withFolderAccessNodes
  :: (MonadThrow m, KatipContext m, Traversable t)
  => [LocationTreePathItem]              -- ^ Path to folder in 'LocationTree'
  -> t (LTPIAndSubtree VirtualFileNode)  -- ^ Items of interest in the subfolder
  -> (t (DataAccessNode m) -> i -> m o)  -- ^ What to run with these items
  -> PTask m i o                         -- ^ The resulting PTask
withFolderAccessNodes path filesToAccess accessFn =
  makePTask tree runAccess
  where
    tree = foldr (\pathItem subtree -> folderNode [ pathItem :/ subtree ])
                 (folderNode $ F.toList filesToAccess) path
    runAccess rscTree input = do
      let mbSubtree = rscTree ^? atSubfolderRec path
      subtree <- case mbSubtree of
        Just s -> return s
        Nothing -> throwWithPrefix $
          "path '" ++ show path ++ "' not found in the LocationTree"
      nodeTags <- forM filesToAccess $ \(filePathItem :/ _) -> do
        case subtree ^? atSubfolder filePathItem . locTreeNodeTag of
          Nothing -> throwWithPrefix $
            "path '" ++ show filePathItem ++ "' not found in the LocationTree"
          Just tag -> return tag
      accessFn nodeTags input

-- | Returns the locs mapped to some path in the location tree. It *doesn't*
-- expose this path as a requirement (hence the result list may be empty, as no
-- mapping might exist). SHOULD NOT BE USED UNLESS loadData/writeData cannot do
-- what you want.
getLocsMappedTo :: (KatipContext m, MonadThrow m)
                => [LocationTreePathItem] -> PTask m () [Loc]
getLocsMappedTo path = runnableWithoutReqs $ withRunnableState $
                         \state _ -> getLocs $ state^.ptrsDataAccessTree
  where
    onErr (Left s) = throwWithPrefix $
      "getLocsMappedTo (" ++ T.unpack (toTextRepr (LTP path)) ++ "): " ++ s
    onErr (Right x) = return x
    getLocs tree =
      case tree ^? (atSubfolderRec path . locTreeNodeTag) of
        -- NOTE: Will fail on repeated folders (because here we can only access
        -- the final locations -- with variables spliced in -- in the case of
        -- nodes with a data access function, not intermediary folders).
        Just (MbDataAccessNode locsWithVars (First mbAccess)) -> case mbAccess of
          Just (SomeDataAccess fn) -> onErr $ daLocsAccessed $ fn mempty
          Nothing -> onErr $ traverse terminateLocWithVars locsWithVars
        _ -> return []
