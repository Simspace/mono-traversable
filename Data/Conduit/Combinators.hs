{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
-- | This module is meant as a replacement for Data.Conduit.List.
-- That module follows a naming scheme which was originally inspired
-- by its enumerator roots. This module is meant to introduce a naming
-- scheme which encourages conduit best practices.
--
-- There are two versions of functions in this module. Those with a trailing
-- E work in the individual elements of a chunk of data, e.g., the bytes of
-- a ByteString, the Chars of a Text, or the Ints of a Vector Int. Those
-- without a trailing E work on unchunked streams.
--
-- FIXME: discuss overall naming, usage of mono-traversable, etc
--
-- Mention take (Conduit) vs drop (Consumer)
module Data.Conduit.Combinators
    ( -- * Producers
      -- ** Pure
      yieldMany
    , unfold
    , enumFromTo
    , iterate
    , repeat
    , replicate
    , sourceLazy

      -- ** Monadic
    , repeatM
    , repeatWhileM
    , replicateM

      -- ** I\/O
    , sourceFile
    , sourceHandle
    , sourceIOHandle

      -- * Consumers
      -- ** Pure
    , drop
    , dropE
    , dropWhile
    , dropWhileE
    , fold
    , foldE
    , foldl
    , foldlE
    , foldMap
    , foldMapE
    , all
    , allE
    , any
    , anyE
    , and
    , andE
    , or
    , orE
    , elem
    , elemE
    , notElem
    , notElemE
    , sinkLazy
    , sinkList
    , sinkVector
    , sinkBuilder
    , sinkLazyBuilder
    , sinkNull
    , awaitNonNull
    , peek
    , peekE
    , last
    , lastE
    , length
    , lengthE
    , maximum
    , maximumE
    , minimum
    , minimumE
    , null
    , nullE
    , sum
    , sumE
    , product
    , productE

      -- ** Monadic
    , mapM_
    , mapM_E
    , foldM
    , foldME
    , foldMapM
    , foldMapME

      -- ** I\/O
    , sinkFile
    , sinkHandle
    , sinkIOHandle

      -- * Transformers
      -- ** Pure
    , map
    , mapE
    , omapE
    , concatMap
    , concatMapE
    , take
    , takeE
    , takeWhile
    , takeWhileE
    , takeExactly
    , takeExactlyE
    , concat
    , filter
    , filterE
    , mapWhile
    , conduitVector

-- FIXME need to organized/document below this point.
      -- ** Monadic
    , mapM
    , mapME
    , omapME
    , concatMapM
    , filterM
    , filterME
    , iterM
    ) where

-- BEGIN IMPORTS

import Data.Builder
import qualified Data.NonNull as NonNull
import qualified Data.Traversable
import           Control.Applicative         ((<$>))
import           Control.Category            (Category (..))
import           Control.Monad               (unless, when, (>=>), liftM, forever)
import           Control.Monad.Base          (MonadBase (liftBase))
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.Primitive     (PrimMonad)
import           Control.Monad.Trans.Class   (lift)
import           Data.Conduit
import qualified Data.Conduit.List           as CL
import           Data.IOData
import           Data.Monoid                 (Monoid (..))
import           Data.MonoTraversable
import qualified Data.Sequences              as Seq
import           Data.Sequences.Lazy
import qualified Data.Vector.Generic         as V
import qualified Data.Vector.Generic.Mutable as VM
import qualified Filesystem                  as F
import           Filesystem.Path             (FilePath)
import           Prelude                     (Bool (..), Eq (..), Int,
                                              Maybe (..), Monad (..), Num (..),
                                              Ord (..), fromIntegral, maybe,
                                              ($), Functor (..))
import           System.IO                   (Handle)
import qualified System.IO                   as SIO

-- END IMPORTS

-- | Yield each of the values contained by the given @MonoFoldable@.
--
-- This will work on many data structures, including lists, @ByteString@s, and @Vector@s.
--
-- Since 1.0.0
yieldMany :: (Monad m, MonoFoldable mono)
          => mono
          -> Producer m (Element mono)
yieldMany = ofoldMap yield
{-# INLINE yieldMany #-}

-- | Generate a producer from a seed value.
--
-- Since 1.0.0
unfold :: Monad m
       => (b -> Maybe (a, b))
       -> b
       -> Producer m a
unfold = CL.unfold
{-# INLINE unfold #-}

-- | Enumerate from a value to a final value, inclusive, via 'succ'.
--
-- This is generally more efficient than using @Prelude@\'s @enumFromTo@ and
-- combining with @sourceList@ since this avoids any intermediate data
-- structures.
--
-- Since 1.0.0
enumFromTo = CL.enumFromTo

-- | Produces an infinite stream of repeated applications of f to x.
--
-- Since 1.0.0
iterate = CL.iterate
{-# INLINE iterate #-}

-- | Produce an infinite stream consisting entirely of the given value.
--
-- Since 1.0.0
repeat = iterate id
{-# INLINE repeat #-}

-- | Produce a finite stream consisting of n copies of the given value.
--
-- Since 1.0.0
replicate :: Monad m
          => Int
          -> a
          -> Producer m a
replicate count0 a =
    loop count0
  where
    loop count = if count <= 0
        then return ()
        else yield a >> loop (count - 1)
{-# INLINE replicate #-}

-- | Generate a producer by yielding each of the strict chunks in a @LazySequence@.
--
-- For more information, see 'toChunks'.
--
-- Since 1.0.0
sourceLazy :: (Monad m, LazySequence lazy strict)
           => lazy
           -> Producer m strict
sourceLazy = yieldMany . toChunks
{-# INLINE sourceLazy #-}

-- | Repeatedly run the given action and yield all values it produces.
--
-- Since 1.0.0
repeatM :: Monad m
        => m a
        -> Producer m a
repeatM m = forever $ lift m >>= yield
{-# INLINE repeatM #-}

-- | Repeatedly run the given action and yield all values it produces, until
-- the provided predicate returns @False@.
--
-- Since 1.0.0
repeatWhileM :: Monad m
             => m a
             -> (a -> Bool)
             -> Producer m a
repeatWhileM m f =
    loop
  where
    loop = do
        x <- lift m
        when (f x) $ yield x >> loop

-- | Perform the given action n times, yielding each result.
--
-- Since 1.0.0
replicateM :: Monad m
           => Int
           -> m a
           -> Producer m a
replicateM count0 m =
    loop count0
  where
    loop count = if count <= 0
        then return ()
        else lift m >>= yield >> loop (count - 1)
{-# INLINE replicateM #-}

-- | Read all data from the given file.
--
-- This function automatically opens and closes the file handle, and ensures
-- exception safety via @MonadResource. It works for all instances of @IOData@,
-- including @ByteString@ and @Text@.
--
-- Since 1.0.0
sourceFile :: (MonadResource m, IOData a) => FilePath -> Producer m a
sourceFile fp = sourceIOHandle (F.openFile fp SIO.ReadMode)
{-# INLINE sourceFile #-}

-- | Read all data from the given @Handle@.
--
-- Does not close the @Handle@ at any point.
--
-- Since 1.0.0
sourceHandle :: (MonadIO m, IOData a) => Handle -> Producer m a
sourceHandle h =
    loop
  where
    loop = do
        x <- liftIO (hGetChunk h)
        if onull x
            then return ()
            else yield x >> loop
{-# INLINEABLE sourceHandle #-}

-- | Open a @Handle@ using the given function and stream data from it.
--
-- Automatically closes the file at completion.
--
-- Since 1.0.0
sourceIOHandle :: (MonadResource m, IOData a) => SIO.IO Handle -> Producer m a
sourceIOHandle alloc = bracketP alloc SIO.hClose sourceHandle
{-# INLINE sourceIOHandle #-}

-- | Ignore a certain number of values in the stream.
--
-- Since 1.0.0
drop :: Monad m
     => Int
     -> Consumer a m ()
drop =
    loop
  where
    loop i | i <= 0 = return ()
    loop count = await >>= maybe (return ()) (\_ -> loop (count - 1))
{-# INLINE drop #-}

-- | Drop a certain number of elements from a chunked stream.
--
-- Since 1.0.0
dropE :: (Monad m, Seq.IsSequence seq)
      => Seq.Index seq
      -> Consumer seq m ()
dropE =
    loop
  where
    loop i = if i <= 0
        then return ()
        else await >>= maybe (return ()) (go i)

    go i seq = do
        unless (onull y) $ leftover y
        loop i'
      where
        (x, y) = Seq.splitAt i seq
        i' = i - fromIntegral (olength x)
{-# INLINEABLE dropE #-}

-- | Drop all values which match the given predicate.
--
-- Since 1.0.0
dropWhile :: Monad m
          => (a -> Bool)
          -> Consumer a m ()
dropWhile f =
    loop
  where
    loop = await >>= maybe (return ()) go
    go x = if f x then loop else leftover x
{-# INLINE dropWhile #-}

-- | Drop all elements in the chunked stream which match the given predicate.
--
-- Since 1.0.0
dropWhileE :: (Monad m, Seq.IsSequence seq)
           => (Element seq -> Bool)
           -> Consumer seq m ()
dropWhileE f =
    loop
  where
    loop = await >>= maybe (return ()) go

    go seq =
        if onull x then loop else leftover x
      where
        x = Seq.dropWhile f seq
{-# INLINE dropWhileE #-}

-- | Monoidally combine all values in the stream.
--
-- Since 1.0.0
fold :: (Monad m, Monoid a)
     => Consumer a m a
fold = CL.foldMap id
{-# INLINE fold #-}

-- | Monoidally combine all elements in the chunked stream.
--
-- Since 1.0.0
foldE :: (Monad m, MonoFoldable mono, Monoid (Element mono))
      => Consumer mono m (Element mono)
foldE = CL.fold (\accum mono -> accum `mappend` ofoldMap id mono) mempty
{-# INLINE foldE #-}

-- | A strict left fold.
--
-- Since 1.0.0
foldl = CL.fold
{-# INLINE foldl #-}

-- | A strict left fold on a chunked stream.
--
-- Since 1.0.0
foldlE :: (Monad m, MonoFoldable mono)
       => (a -> Element mono -> a)
       -> a
       -> Consumer mono m a
foldlE f = CL.fold (ofoldl' f)
{-# INLINE foldlE #-}

-- | Apply the provided mapping function and monoidal combine all values.
--
-- Since 1.0.0
foldMap :: (Monad m, Monoid b)
        => (a -> b)
        -> Consumer a m b
foldMap = CL.foldMap
{-# INLINE foldMap #-}

-- | Apply the provided mapping function and monoidal combine all elements of the chunked stream.
--
-- Since 1.0.0
foldMapE :: (Monad m, MonoFoldable mono, Monoid w)
         => (Element mono -> w)
         -> Consumer mono m w
foldMapE = CL.foldMap . ofoldMap
{-# INLINE foldMapE #-}

-- | Check that all values in the stream return True.
--
-- Subject to shortcut logic: at the first False, consumption of the stream
-- will stop.
--
-- Since 1.0.0
all :: Monad m
    => (a -> Bool)
    -> Consumer a m Bool
all f =
    loop
  where
    loop = await >>= maybe (return True) go
    go x = if f x then loop else return False
{-# INLINE all #-}

-- | Check that all elements in the chunked stream return True.
--
-- Subject to shortcut logic: at the first False, consumption of the stream
-- will stop.
--
-- Since 1.0.0
allE :: (Monad m, MonoFoldable mono)
     => (Element mono -> Bool)
     -> Consumer mono m Bool
allE = all . oall

-- | Check that at least one value in the stream returns True.
--
-- Subject to shortcut logic: at the first True, consumption of the stream
-- will stop.
--
-- Since 1.0.0
any :: Monad m
    => (a -> Bool)
    -> Consumer a m Bool
any f =
    loop
  where
    loop = await >>= maybe (return False) go
    go x = if f x then return True else loop
{-# INLINE any #-}

-- | Check that at least one element in the chunked stream returns True.
--
-- Subject to shortcut logic: at the first True, consumption of the stream
-- will stop.
--
-- Since 1.0.0
anyE :: (Monad m, MonoFoldable mono)
     => (Element mono -> Bool)
     -> Consumer mono m Bool
anyE = any . oany

-- | Are all values in the stream True?
--
-- Consumption stops once the first False is encountered.
--
-- Since 1.0.0
and :: Monad m => Consumer Bool m Bool
and = all id
{-# INLINE and #-}

-- | Are all elements in the chunked stream True?
--
-- Consumption stops once the first False is encountered.
--
-- Since 1.0.0
andE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
     => Consumer mono m Bool
andE = allE id
{-# INLINE andE #-}

-- | Are any values in the stream True?
--
-- Consumption stops once the first True is encountered.
--
-- Since 1.0.0
or :: Monad m => Consumer Bool m Bool
or = any id
{-# INLINE or #-}

-- | Are any elements in the chunked stream True?
--
-- Consumption stops once the first True is encountered.
--
-- Since 1.0.0
orE :: (Monad m, MonoFoldable mono, Element mono ~ Bool)
    => Consumer mono m Bool
orE  = anyE id
{-# INLINE orE #-}

-- | Are any values in the stream equal to the given value?
--
-- Stops consuming as soon as a match is found.
--
-- Since 1.0.0
elem :: (Monad m, Eq a) => a -> Consumer a m Bool
elem x = any (== x)
{-# INLINE elem #-}

-- | Are any elements in the chunked stream equal to the given element?
--
-- Stops consuming as soon as a match is found.
--
-- Since 1.0.0
elemE :: (Monad m, Seq.EqSequence seq)
      => Element seq
      -> Consumer seq m Bool
elemE = any . Seq.elem

-- | Are no values in the stream equal to the given value?
--
-- Stops consuming as soon as a match is found.
--
-- Since 1.0.0
notElem :: (Monad m, Eq a) => a -> Consumer a m Bool
notElem x = all (/= x)
{-# INLINE notElem #-}

-- | Are no elements in the chunked stream equal to the given element?
--
-- Stops consuming as soon as a match is found.
--
-- Since 1.0.0
notElemE :: (Monad m, Seq.EqSequence seq)
         => Element seq
         -> Consumer seq m Bool
notElemE = all . Seq.notElem

-- | Consume all incoming strict chunks into a lazy sequence.
-- Note that the entirety of the sequence will be resident at memory.
--
-- This can be used to consume a stream of strict ByteStrings into a lazy
-- ByteString, for example.
--
-- Since 1.0.0
sinkLazy :: (Monad m, LazySequence lazy strict)
         => Consumer strict m lazy
sinkLazy = (fromChunks . ($ [])) <$> CL.fold (\front next -> front . (next:)) id
{-# INLINE sinkLazy #-}

-- | Consume all values from the stream and return as a list. Note that this
-- will pull all values into memory.
--
-- Since 1.0.0
sinkList = CL.consume
{-# INLINE sinkList #-}

-- | Sink incoming values into a vector, up until size @maxSize@.  Subsequent
-- values will be left in the stream. If there are less than @maxSize@ values
-- present, returns a @Vector@ of smaller size.
--
-- Note that using this function is more memory efficient than @sinkList@ and
-- then converting to a @Vector@, as it avoids intermediate list constructors.
--
-- Since 1.0.0
sinkVector :: (MonadBase base m, V.Vector v a, PrimMonad base)
           => Int -- ^ maximum allowed size
           -> Consumer a m (v a)
sinkVector maxSize = do
    mv <- liftBase $ VM.new maxSize
    let go i | i >= maxSize = liftBase $ V.unsafeFreeze mv
        go i = do
            mx <- await
            case mx of
                Nothing -> V.slice 0 i <$> liftBase (V.unsafeFreeze mv)
                Just x -> do
                    liftBase $ VM.write mv i x
                    go (i + 1)
    go 0
{-# INLINEABLE sinkVector #-}

-- | Convert incoming values to a builder and fold together all builder values.
--
-- Defined as: @foldMap toBuilder@.
--
-- Since 1.0.0
sinkBuilder = foldMap toBuilder
{-# INLINE sinkBuilder #-}

-- | Same as @sinkBuilder@, but afterwards convert the builder to its lazy
-- representation.
--
-- Alternatively, this could be considered an alternative to @sinkLazy@, with
-- the following differences:
--
-- * This function will allow multiple input types, not just the strict version
-- of the lazy structure.
--
-- * Some buffer copying may occur in this version.
--
-- Since 1.0.0
sinkLazyBuilder = fmap builderToLazy sinkBuilder
{-# INLINE sinkLazyBuilder #-}

-- | Consume and discard all remaining values in the stream.
--
-- Since 1.0.0
sinkNull = CL.sinkNull
{-# INLINE sinkNull #-}

-- | Same as @await@, but discards any leading 'onull' values.
--
-- Since 1.0.0
awaitNonNull =
    go
  where
    go = await >>= maybe (return Nothing) go'

    go' = maybe go (return . Just) . NonNull.fromNullable
{-# INLINE awaitNonNull #-}

-- | View the next value in the stream without consuming it.
--
-- Since 1.0.0
peek = CL.peek
{-# INLINE peek #-}

-- | View the next element in the chunked stream without consuming it.
--
-- Since 1.0.0
peekE =
    loop
  where
    loop = await >>= maybe (return Nothing) go
    go x =
        case Seq.headMay x of
            Nothing -> loop
            Just y -> do
                leftover x
                return $ Just y
{-# INLINE peekE #-}

-- | Retrieve the last value in the stream, if present.
--
-- Since 1.0.0
last =
    await >>= maybe (return Nothing) loop
  where
    loop prev = await >>= maybe (return $ Just prev) loop
{-# INLINE last #-}

-- | Retrieve the last element in the chunked stream, if present.
--
-- Since 1.0.0
lastE =
    awaitNonNull >>= maybe (return Nothing) (loop . NonNull.last . asNotEmpty)
  where

    loop prev = awaitNonNull >>= maybe (return $ Just prev) (loop . NonNull.last . asNotEmpty)
{-# INLINE lastE #-}

-- | Count how many values are in the stream.
--
-- Since 1.0.0
length = foldl (\x _ -> x + 1) 0
{-# INLINE length #-}

-- | Count how many elements are in the chunked stream.
--
-- Since 1.0.0
lengthE = foldl (\x y -> x + olength y) 0
{-# INLINE lengthE #-}

-- | Get the largest value in the stream, if present.
--
-- Since 1.0.0
maximum =
    await >>= maybe (return Nothing) loop
  where
    loop prev = await >>= maybe (return $ Just prev) (loop . max prev)
{-# INLINE maximum #-}

-- | Get the largest element in the chunked stream, if present.
--
-- Since 1.0.0
maximumE =
    start
  where
    start = await >>= maybe (return Nothing) start'
    start' x =
        case NonNull.fromNullable x of
            Nothing -> start
            Just y -> loop $ NonNull.maximum $ asNotEmpty y
    loop prev = await >>= maybe (return $ Just prev) (loop . ofoldl' max prev)
{-# INLINE maximumE #-}

asNotEmpty :: NonNull.NotEmpty a -> NonNull.NotEmpty a
asNotEmpty = id

-- | Get the smallest value in the stream, if present.
--
-- Since 1.0.0
minimum =
    await >>= maybe (return Nothing) loop
  where
    loop prev = await >>= maybe (return $ Just prev) (loop . min prev)
{-# INLINE minimum #-}

-- | Get the smallest element in the chunked stream, if present.
--
-- Since 1.0.0
minimumE =
    start
  where
    start = await >>= maybe (return Nothing) start'
    start' x =
        case NonNull.fromNullable x of
            Nothing -> start
            Just y -> loop $ NonNull.minimum $ asNotEmpty y
    loop prev = await >>= maybe (return $ Just prev) (loop . ofoldl' min prev)
{-# INLINE minimumE #-}

-- | True if there are no values in the stream.
--
-- This function does not modify the stream.
--
-- Since 1.0.0
null = (maybe True (\_ -> False)) `fmap` peek
{-# INLINE null #-}

-- | True if there are no elements in the chunked stream.
--
-- This function may remove empty leading chunks from the stream, but otherwise
-- will not modify it.
--
-- Since 1.0.0
nullE :: (Monad m, MonoFoldable mono)
      => Consumer mono m Bool
nullE =
    go
  where
    go = await >>= maybe (return True) go'
    go' x = if onull x then go else leftover x >> return False
{-# INLINE nullE #-}

-- | Get the sum of all values in the stream.
--
-- Since 1.0.0
sum = foldl (+) 0
{-# INLINE sum #-}

-- | Get the sum of all elements in the chunked stream.
--
-- Since 1.0.0
sumE = foldlE (+) 0
{-# INLINE sumE #-}

-- | Get the product of all values in the stream.
--
-- Since 1.0.0
product = foldl (*) 1
{-# INLINE product #-}

-- | Get the product of all elements in the chunked stream.
--
-- Since 1.0.0
productE = foldlE (*) 1
{-# INLINE productE #-}

-- | Apply the action to all values in the stream.
--
-- Since 1.0.0
mapM_ = CL.mapM_
{-# INLINE mapM_ #-}

-- | Apply the action to all elements in the chunked stream.
--
-- Since 1.0.0
mapM_E = CL.mapM_ . omapM_
{-# INLINE mapM_E #-}

-- | A monadic strict left fold.
--
-- Since 1.0.0
foldM = CL.foldM
{-# INLINE foldM #-}

-- | A monadic strict left fold on a chunked stream.
--
-- Since 1.0.0
foldME :: (Monad m, MonoFoldable mono)
       => (a -> Element mono -> m a)
       -> a
       -> Consumer mono m a
foldME f = foldM (ofoldlM f)
{-# INLINE foldME #-}

-- | Apply the provided monadic mapping function and monoidal combine all values.
--
-- Since 1.0.0
foldMapM = CL.foldMapM
{-# INLINE foldMapM #-}

-- | Apply the provided monadic mapping function and monoidal combine all
-- elements in the chunked stream.
--
-- Since 1.0.0
foldMapME :: (Monad m, MonoFoldable mono, Monoid w)
          => (Element mono -> m w)
          -> Consumer mono m w
foldMapME f =
    CL.foldM go mempty
  where
    go = ofoldlM (\accum e -> mappend accum `liftM` f e)
{-# INLINE foldMapME #-}

-- | Write all data to the given file.
--
-- This function automatically opens and closes the file handle, and ensures
-- exception safety via @MonadResource. It works for all instances of @IOData@,
-- including @ByteString@ and @Text@.
--
-- Since 1.0.0
sinkFile :: (MonadResource m, IOData a) => FilePath -> Consumer a m ()
sinkFile fp = sinkIOHandle (F.openFile fp SIO.WriteMode)
{-# INLINE sinkFile #-}

-- | Write all data to the given @Handle@.
--
-- Does not close the @Handle@ at any point.
--
-- Since 1.0.0
sinkHandle :: (MonadIO m, IOData a) => Handle -> Consumer a m ()
sinkHandle = CL.mapM_ . hPut
{-# INLINE sinkHandle #-}

-- | Open a @Handle@ using the given function and stream data to it.
--
-- Automatically closes the file at completion.
--
-- Since 1.0.0
sinkIOHandle :: (MonadResource m, IOData a) => SIO.IO Handle -> Consumer a m ()
sinkIOHandle alloc = bracketP alloc SIO.hClose sinkHandle
{-# INLINE sinkIOHandle #-}

-- | Apply a transformation to all values in a stream.
--
-- Since 1.0.0
map = CL.map
{-# INLINE map #-}

-- | Apply a transformation to all elements in a chunked stream.
--
-- Since 1.0.0
mapE = CL.map . fmap
{-# INLINE mapE #-}

-- | Apply a monomorphic transformation to all elements in a chunked stream.
--
-- Unlike @mapE@, this will work on types like @ByteString@ and @Text@ which
-- are @MonoFunctor@ but not @Functor@.
--
-- Since 1.0.0
omapE = CL.map . omap
{-# INLINE omapE #-}

-- | Apply the function to each value in the stream, resulting in a foldable
-- value (e.g., a list). Then yield each of the individual values in that
-- foldable value separately.
--
-- Generalizes concatMap, mapMaybe, and mapFoldable.
--
-- Since 1.0.0
concatMap :: (Monad m, MonoFoldable mono)
          => (a -> mono)
          -> Conduit a m (Element mono)
concatMap f = awaitForever (yieldMany . f)
{-# INLINE concatMap #-}

-- | Apply the function to each element in the chunked stream, resulting in a
-- foldable value (e.g., a list). Then yield each of the individual values in
-- that foldable value separately.
--
-- Generalizes concatMap, mapMaybe, and mapFoldable.
--
-- Since 1.0.0
concatMapE :: (Monad m, MonoFoldable mono, Monoid w)
           => (Element mono -> w)
           -> Conduit mono m w
concatMapE = CL.map . ofoldMap
{-# INLINE concatMapE #-}

-- | Stream up to n number of values downstream.
--
-- Note that, if downstream terminates early, not all values will be consumed.
-- If you want to force /exactly/ the given number of values to be consumed,
-- see 'takeExactly'.
--
-- Since 1.0.0
take :: Monad m => Int -> Conduit a m a
take =
    loop
  where
    loop count = if count <= 0
        then return ()
        else await >>= maybe (return ()) (\i -> yield i >> loop (count - 1))
{-# INLINE take #-}

-- | Stream up to n number of elements downstream in a chunked stream.
--
-- Note that, if downstream terminates early, not all values will be consumed.
-- If you want to force /exactly/ the given number of values to be consumed,
-- see 'takeExactlyE'.
--
-- Since 1.0.0
takeE :: (Monad m, Seq.IsSequence seq)
      => Seq.Index seq
      -> Conduit seq m seq
takeE =
    loop
  where
    loop i = if i <= 0
        then return ()
        else await >>= maybe (return ()) (go i)

    go i seq = do
        unless (onull x) $ yield x
        unless (onull y) $ leftover y
        loop i'
      where
        (x, y) = Seq.splitAt i seq
        i' = i - fromIntegral (olength x)
{-# INLINEABLE takeE #-}

-- | Stream all values downstream that match the given predicate.
--
-- Same caveats regarding downstream termination apply as with 'take'.
--
-- Since 1.0.0
takeWhile :: Monad m
          => (a -> Bool)
          -> Conduit a m a
takeWhile f =
    loop
  where
    loop = await >>= maybe (return ()) go
    go x = if f x
        then yield x >> loop
        else leftover x
{-# INLINE takeWhile #-}

-- | Stream all elements downstream that match the given predicate in a chunked stream.
--
-- Same caveats regarding downstream termination apply as with 'takeE'.
--
-- Since 1.0.0
takeWhileE :: (Monad m, Seq.IsSequence seq)
           => (Element seq -> Bool)
           -> Conduit seq m seq
takeWhileE f =
    loop
  where
    loop = await >>= maybe (return ()) go

    go seq = do
        unless (onull x) $ yield x
        if onull y
            then loop
            else leftover y
      where
        (x, y) = Seq.span f seq
{-# INLINE takeWhileE #-}

-- | Consume precisely the given number of values and feed them downstream.
--
-- This function is in contrast to 'take', which will only consume up to the
-- given number of values, and will terminate early if downstream terminates
-- early. This function will discard any additional values in the stream if
-- they are unconsumed.
--
-- Note that this function takes a downstream @ConduitM@ as a parameter, as
-- opposed to working with normal fusion. For more information, see
-- <http://www.yesodweb.com/blog/2013/10/core-flaw-pipes-conduit>, the section
-- titled \"pipes and conduit: isolate\".
--
-- Since 1.0.0
takeExactly :: Monad m
            => Int
            -> ConduitM a b m r
            -> ConduitM a b m r
takeExactly count inner = take count =$= do
    r <- inner
    CL.sinkNull
    return r
{-# INLINE takeExactly #-}

-- | Same as 'takeExactly', but for chunked streams.
--
-- Since 1.0.0
takeExactlyE :: (Monad m, Seq.IsSequence a)
             => Seq.Index a
             -> ConduitM a b m r
             -> ConduitM a b m r
takeExactlyE count inner = takeE count =$= do
    r <- inner
    CL.sinkNull
    return r
{-# INLINE takeExactlyE #-}

-- | Flatten out a stream by yielding the values contained in an incoming
-- @MonoFoldable@ as individually yielded values.
--
-- Since 1.0.0
concat :: (Monad m, MonoFoldable mono)
       => Conduit mono m (Element mono)
concat = awaitForever yieldMany
{-# INLINE concat #-}

-- | Keep only values in the stream passing a given predicate.
--
-- Since 1.0.0
filter = CL.filter
{-# INLINE filter #-}

-- | Keep only elements in the chunked stream passing a given predicate.
--
-- Since 1.0.0
filterE = CL.map . Seq.filter
{-# INLINE filterE #-}

-- | Map values as long as the result is @Just@.
--
-- Since 1.0.0
mapWhile :: Monad m => (a -> Maybe b) -> Conduit a m b
mapWhile f =
    loop
  where
    loop = await >>= maybe (return ()) go
    go x =
        case f x of
            Just y -> yield y >> loop
            Nothing -> leftover x
{-# INLINE mapWhile #-}

-- | Break up a stream of values into vectors of size n. The final vector may
-- be smaller than n if the total number of values is not a strict multiple of
-- n. No empty vectors will be yielded.
--
-- Since 1.0.0
conduitVector size =
    loop
  where
    loop = do
        v <- sinkVector size
        unless (V.null v) $ do
            yield v
            loop
{-# INLINE conduitVector #-}

-- | Apply a monadic transformation to all values in a stream.
--
-- If you do not need the transformed values, and instead just want the monadic
-- side-effects of running the action, see 'mapM_'.
--
-- Since 1.0.0
mapM = CL.mapM
{-# INLINE mapM #-}

-- | Apply a monadic transformation to all elements in a chunked stream.
--
-- Since 1.0.0
mapME = CL.mapM . Data.Traversable.mapM
{-# INLINE mapME #-}

-- | Apply a monadic monomorphic transformation to all elements in a chunked stream.
--
-- Unlike @mapME@, this will work on types like @ByteString@ and @Text@ which
-- are @MonoFunctor@ but not @Functor@.
--
-- Since 1.0.0
omapME = CL.mapM . omapM
{-# INLINE omapME #-}

-- | Apply the monadic function to each value in the stream, resulting in a
-- foldable value (e.g., a list). Then yield each of the individual values in
-- that foldable value separately.
--
-- Generalizes concatMapM, mapMaybeM, and mapFoldableM.
--
-- Since 1.0.0
concatMapM :: (Monad m, MonoFoldable mono)
           => (a -> m mono)
           -> Conduit a m (Element mono)
concatMapM f = awaitForever (lift . f >=> yieldMany)
{-# INLINE concatMapM #-}

-- | Keep only values in the stream passing a given monadic predicate.
--
-- Since 1.0.0
filterM :: Monad m
        => (a -> m Bool)
        -> Conduit a m a
filterM f =
    awaitForever go
  where
    go x = do
        b <- lift $ f x
        when b $ yield x
{-# INLINE filterM #-}

-- | Keep only elements in the chunked stream passing a given monadic predicate.
--
-- Since 1.0.0
filterME = CL.mapM . Seq.filterM
{-# INLINE filterME #-}

-- | Apply a monadic action on all values in a stream.
--
-- This @Conduit@ can be used to perform a monadic side-effect for every
-- value, whilst passing the value through the @Conduit@ as-is.
--
-- > iterM f = mapM (\a -> f a >>= \() -> return a)
--
-- Since 1.0.0
iterM = CL.iterM

{-

-- FIXME

lines
unlines
concatMapAccum
scanl
groupBy
scanlM
concatMapAccumM
encode
decode
withLine
print
find
foldLines
intercalate
split
splitWith

-}
