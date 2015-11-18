{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Snap.Snaplet.Persistent
  ( initPersist
  , PersistState(..)
  , HasPersistPool(..)
  , mkPgPool
  , mkSnapletPgPool
  , runPersist
  , runPersist'
  , withPool

  -- * Utility Functions
  , mkKey
  , mkKeyBS
  , mkKeyT
  , showKey
  , showKeyBS
  , mkInt
  , mkWord64
  , followForeignKey
  , fromPersistValue'
  ) where

-------------------------------------------------------------------------------
import           Control.Monad.Catch          as EC
import           Control.Monad.Logger
import           Control.Monad.State
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.Resource
import           Control.Retry
import           Data.ByteString              (ByteString)
import           Data.Configurator
import           Data.Configurator.Types
import           Data.Maybe
import           Data.Readable
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Text.Encoding           as T
import           Data.Word
import           Database.Persist
import           Database.Persist.Class
import           Database.Persist.Postgresql  hiding (get)
import qualified Database.Persist.Postgresql  as DB
import           Database.Persist.Types
import           Paths_snaplet_persistent
import           Snap.Core
import           Snap.Snaplet                 as S
-------------------------------------------------------------------------------

instance MonadThrow Snap where
    throwM = liftSnap . throwM

instance MonadCatch Snap where
    catch e h = liftSnap $ catch e h

-------------------------------------------------------------------------------
newtype PersistState = PersistState { persistPool :: ConnectionPool }


-------------------------------------------------------------------------------
-- | Implement this type class to have any monad work with snaplet-persistent.
-- A default instance is provided for (Handler b PersistState).
class MonadIO m => HasPersistPool m where
    getPersistPool :: m ConnectionPool


instance HasPersistPool m => HasPersistPool (NoLoggingT m) where
    getPersistPool = runNoLoggingT getPersistPool

instance HasPersistPool (S.Handler b PersistState) where
    getPersistPool = gets persistPool

instance MonadIO m => HasPersistPool (ReaderT ConnectionPool m) where
    getPersistPool = ask


-------------------------------------------------------------------------------
-- | Initialize Persistent with an initial SQL function called right
-- after the connection pool has been created. This is most useful for
-- calling migrations upfront right after initialization.
--
-- Example:
--
-- > initPersist (runMigrationUnsafe migrateAll)
--
-- where migrateAll is the migration function that was auto-generated
-- by the QQ statement in your persistent schema definition in the
-- call to 'mkMigrate'.
initPersist :: SqlPersistT (NoLoggingT IO) a -> SnapletInit b PersistState
initPersist migration = makeSnaplet "persist" description datadir $ do
    conf <- getSnapletUserConfig
    p <- liftIO . runNoLoggingT $ mkSnapletPgPool conf

    liftIO . runNoLoggingT $ runSqlPool migration p
    return $ PersistState p
  where
    description = "Snaplet for persistent DB library"
    datadir = Just $ liftM (++"/resources/db") getDataDir


-------------------------------------------------------------------------------
-- | Constructs a connection pool from Config.
mkPgPool :: (MonadLogger m, MonadBaseControl IO m, MonadIO m) => Config -> m ConnectionPool
mkPgPool conf = do
  pgConStr <- liftIO $ require conf "postgre-con-str"
  cons <- liftIO $ require conf "postgre-pool-size"
  createPostgresqlPool pgConStr cons

-------------------------------------------------------------------------------
-- | Constructs a connection pool in a snaplet context.
mkSnapletPgPool :: (MonadBaseControl IO m, MonadLogger m, MonadIO m, EC.MonadCatch m) => Config -> m ConnectionPool
mkSnapletPgPool = mkPgPool

-------------------------------------------------------------------------------
-- | Runs a SqlPersist action in any monad with a HasPersistPool instance.
runPersist :: (HasPersistPool m, MonadSnap m)
           => SqlPersistT (ResourceT (NoLoggingT IO)) b
           -- ^ Run given Persistent action in the defined monad.
           -> m b
runPersist act = getPersistPool >>= \p -> liftSnap (withPool p act)

runPersist' :: (HasPersistPool m)
            => SqlPersistT (ResourceT (NoLoggingT IO)) b
            -- ^ Run given Persistent action in the defined monad.
            -> m b
runPersist' act = getPersistPool >>= \p -> withPool p act

------------------------------------------------------------------------------
-- | Run a database action, if a `PersistentSqlException` is raised
-- the action will be retried four times with a 50ms delay between
-- each retry.
--
-- This is being done because sometimes Postgres will reap connections
-- and the connection leased out of the pool may then be stale and
-- will often times throw a `Couldn'tGetSQLConnection` type value.

withPool :: MonadIO m
         => ConnectionPool
         -> SqlPersistT (ResourceT (NoLoggingT IO)) a
         -> m a
withPool cp f = liftIO $ recoverAll retryPolicy $ runF f cp
  where
    retryPolicy = constantDelay 50000 <> limitRetries 5
    runF f' cp' = liftIO . runNoLoggingT . runResourceT $ runSqlPool f' cp'

-------------------------------------------------------------------------------
-- | Make a Key from an Int.
mkKey :: ToBackendKey SqlBackend entity => Int -> Key entity
mkKey = fromBackendKey . SqlBackendKey . fromIntegral


-------------------------------------------------------------------------------
-- | Makes a Key from a ByteString.  Calls error on failure.
mkKeyBS :: ToBackendKey SqlBackend entity => ByteString -> Key entity
mkKeyBS = mkKey . fromMaybe (error "Can't ByteString value") . fromBS


-------------------------------------------------------------------------------
-- | Makes a Key from Text.  Calls error on failure.
mkKeyT :: ToBackendKey SqlBackend entity => Text -> Key entity
mkKeyT = mkKey . fromMaybe (error "Can't Text value") . fromText


-------------------------------------------------------------------------------
-- | Makes a Text representation of a Key.
showKey :: ToBackendKey SqlBackend e => Key e -> Text
showKey = T.pack . show . mkInt


-------------------------------------------------------------------------------
-- | Makes a ByteString representation of a Key.
showKeyBS :: ToBackendKey SqlBackend e => Key e -> ByteString
showKeyBS = T.encodeUtf8 . showKey


-------------------------------------------------------------------------------
-- | Converts a Key to Int.  Fails with error if the conversion fails.
mkInt :: ToBackendKey SqlBackend a => Key a -> Int
mkInt = fromIntegral . unSqlBackendKey . toBackendKey


-------------------------------------------------------------------------------
-- | Converts a Key to Word64.  Fails with error if the conversion fails.
mkWord64 :: ToBackendKey SqlBackend a => Key a -> Word64
mkWord64 = fromIntegral . unSqlBackendKey . toBackendKey


-------------------------------------------------------------------------------
-- Converts a PersistValue to a more concrete type.  Calls error if the
-- conversion fails.
fromPersistValue' :: PersistField c => PersistValue -> c
fromPersistValue' = either (const $ error "Persist conversion failed") id
                    . fromPersistValue


------------------------------------------------------------------------------
-- | Follows a foreign key field in one entity and retrieves the corresponding
-- entity from the database.
followForeignKey :: (PersistEntity a, HasPersistPool m,
                     PersistEntityBackend a ~ SqlBackend)
                 => (t -> Key a) -> Entity t -> m (Maybe (Entity a))
followForeignKey toKey (Entity _ val) = do
    let key' = toKey val
    mval <- runPersist' $ DB.get key'
    return $ fmap (Entity key') mval
