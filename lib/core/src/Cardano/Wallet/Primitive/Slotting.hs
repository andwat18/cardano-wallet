{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE Rank2Types #-}

-- |
-- Copyright: © 2018-2020 IOHK
-- License: Apache-2.0
--
-- Contains tools for converting between @SlotNo@, @EpochNo@, @SlotInEpoch@,
-- @UTCTime@.

module Cardano.Wallet.Primitive.Slotting
    ( -- * New api using ouroboros-concensus
      -- ** Queries
      currentEpoch
    , epochAt
    , epochOf
    , startTime
    , toSlotId
    , slotRangeFromTimeRange
    , firstSlotInEpoch
    , ongoingSlotAt

    -- ** Running queries
    , TimeInterpreter
    , singleEraInterpreter
    , Qry

      -- * Legacy api
    , unsafeEpochNo
    , epochStartTime
    , epochPred
    , epochSucc
    , SlotParameters (..)
    , slotParams
    , flatSlot
    , fromFlatSlot
    , slotStartTime
    , slotCeiling
    , slotFloor
    , slotAt'
    , slotDifference
    , slotPred
    , slotSucc
    , slotMinBound
    , slotRangeFromTimeRange'
    ) where

import Prelude

import Cardano.Wallet.Primitive.Types
    ( ActiveSlotCoefficient (..)
    , EpochLength (..)
    , EpochNo (..)
    , GenesisParameters (..)
    , Range (..)
    , SlotId (..)
    , SlotInEpoch (..)
    , SlotLength (..)
    , StartTime (..)
    , unsafeEpochNo
    , wholeRange
    )
import Control.Monad
    ( ap, liftM, (<=<) )
import Control.Monad.IO.Class
    ( MonadIO, liftIO )
import Data.Functor.Identity
    ( Identity )
import Data.Generics.Internal.VL.Lens
    ( (^.) )
import Data.Maybe
    ( fromMaybe )
import Data.Quantity
    ( Quantity (..) )
import Data.Time.Clock
    ( NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime )
import Data.Word
    ( Word32, Word64 )
import GHC.Generics
    ( Generic )
import Numeric.Natural
    ( Natural )
import Ouroboros.Consensus.HardFork.History.EraParams
    ( EraParams (..), noLowerBoundSafeZone )
import Ouroboros.Consensus.HardFork.History.Summary
    ( Summary (..), neverForksSummary )

import qualified Cardano.Slotting.Slot as Cardano
import qualified Ouroboros.Consensus.BlockchainTime.WallClock.Types as Cardano
import qualified Ouroboros.Consensus.HardFork.History.Qry as HF
import qualified Ouroboros.Consensus.HardFork.History.Summary as HF

-- -----------------------------------------------------------------------------
-- New Api using ouroboros-consensus. With the right interpreter, the
-- calculations don't break on hard-forks.


--
-- Queries
--

currentEpoch :: MonadIO m => TimeInterpreter m -> m (Maybe EpochNo)
currentEpoch ti = ti . epochAt =<< liftIO getCurrentTime

epochAt :: UTCTime -> Qry (Maybe EpochNo)
epochAt = traverse epochOf <=< ongoingSlotAt

epochOf :: Cardano.SlotNo -> Qry EpochNo
epochOf slot = epochNumber <$> toSlotId slot

toSlotId :: Cardano.SlotNo -> Qry SlotId
toSlotId slot = HardForkQry $ do
    (e, s, _) <- HF.slotToEpoch slot
    return $ SlotId
        (EpochNo $ fromIntegral $ Cardano.unEpochNo e)
        (SlotInEpoch $ unsafeConvert s)
  where
    unsafeConvert :: Word64 -> Word32
    unsafeConvert = fromIntegral

startTime :: Cardano.SlotNo -> Qry UTCTime
startTime s = do
    rel <- HardForkQry (fst <$> HF.slotToWallclock s)
    RelToUTCTime rel

-- | Translate 'EpochNo' to the 'SlotNo' of the first slot in that epoch
firstSlotInEpoch :: EpochNo -> Qry Cardano.SlotNo
firstSlotInEpoch = fmap fst . HardForkQry . HF.epochToSlot . convertEpochNo
  where
    convertEpochNo (EpochNo e) = Cardano.EpochNo $ fromIntegral e

slotRangeFromTimeRange
    :: Range UTCTime
    -> Qry (Maybe (Range Cardano.SlotNo))
slotRangeFromTimeRange (Range Nothing Nothing) = pure $ Just wholeRange
slotRangeFromTimeRange (Range low hi) = do
    low' <- liftMay ceilingSlotAt low
    hi' <- liftMay ongoingSlotAt hi
    pure $ Range low' <$> (maybe (Just Nothing) (fmap Just) hi')
  where

    liftMay :: (a -> Qry b) -> Maybe a -> Qry (Maybe b)
    liftMay f (Just x) = Just <$> f x
    liftMay _ Nothing = return Nothing


-- @@
--     slot:
--     |1--------|2----------
--
--     result of onGoingSlotAt:
--     ●---------○
--          1
--               ●----------○
--                    2
-- @@
--
--
ongoingSlotAt :: UTCTime -> Qry (Maybe Cardano.SlotNo)
ongoingSlotAt x = do
     slotAtTimeDetailed x >>= \case
        Just (slot, _timeInSlot, _timeRemainingInSlot) -> pure $ Just slot
        Nothing -> pure Nothing

-- @@
--     slot:
--     |1--------|2----------
--
--     result of ceilingSlotAt:
--     ○---------●
--          2
--               ○----------●
--                    3
-- @@
--
ceilingSlotAt :: UTCTime -> Qry Cardano.SlotNo
ceilingSlotAt t = do
     slotAtTimeDetailed t >>= \case
        Just (s, 0, _) -> return s
        Just (s, _, _) -> return (s + 1)
        Nothing -> do
            return $ Cardano.SlotNo 0

-- | Helper that returns @(slot, elapsedTimeInSlot, remainingTimeInSlot)@ for a
-- given @UTCTime@.
slotAtTimeDetailed
    :: UTCTime
    -> Qry (Maybe (Cardano.SlotNo, NominalDiffTime, NominalDiffTime))
slotAtTimeDetailed t = do
    UTCTimeToRel t >>= \case
        Just relTime -> fmap Just $ HardForkQry $ HF.wallclockToSlot relTime
        Nothing -> return Nothing

-- A @TimeInterpreter@ is a way for the wallet to run things of type @Qry a@.
--
-- NOTE:
-- A @TimeInterpreter@ could in theory decide to update the era summary from the
-- node when running a query.
--
-- We cannot manually specify when the fetching happens.
--
-- This may or may not be what we actually want.
type TimeInterpreter m = forall a. Qry a -> m a
--
-- Interpretation
--

data Interpreter xs = Interpreter
    { _iSummary :: Summary xs
    , _iGenesisStartDate :: StartTime
    }

-- | An 'Interpreter' for a single era, where the slotting from
-- @GenesisParameters@ cannot change.
--
-- Queries can never fail with @singleEraInterpreter@.
singleEraInterpreter :: GenesisParameters -> TimeInterpreter Identity
singleEraInterpreter gp q = either bomb return $ runQuery q int
  where
    bomb x = error $ "singleEraIntepreter: the impossible happened: " <> show x
    int = flip Interpreter (gp ^. #getGenesisBlockDate)
        $ neverForksSummary
        $ EraParams
            { eraEpochSize =
                Cardano.EpochSize
                . fromIntegral
                . unEpochLength
                $ gp ^. #getEpochLength

            , eraSlotLength =
                Cardano.mkSlotLength
                . unSlotLength
                $ gp ^. #getSlotLength

            , eraSafeZone =
                noLowerBoundSafeZone (k * 2)
            }
      where
        k = fromIntegral $ getQuantity $ getEpochStability gp

-- | Wrapper around HF.Qry to allow converting times relative to the genesis
-- block date to absolute ones
data Qry :: * -> * where
    HardForkQry  :: HF.Qry a -> Qry a
    RelToUTCTime :: Cardano.RelativeTime -> Qry UTCTime
    UTCTimeToRel :: UTCTime -> Qry (Maybe Cardano.RelativeTime)
    QPure :: a -> Qry a
    QBind :: Qry a -> (a -> Qry b) -> Qry b

instance Functor Qry where
  fmap = liftM

instance Applicative Qry where
  pure  = QPure
  (<*>) = ap

instance Monad Qry where
  return = pure
  (>>=)  = QBind

runQuery :: (Qry a) -> Interpreter xs -> Either HF.PastHorizonException a
runQuery qry (Interpreter summary (StartTime t0)) = go qry
  where
    go :: Qry a -> Either HF.PastHorizonException a
    go (HardForkQry q) = HF.runQuery q summary
    go (QPure a) =
        return a
    go (QBind x f) = do
        go x >>= go . f
    go (RelToUTCTime rel) =
        pure $ Cardano.fromRelativeTime systemStart rel
    go (UTCTimeToRel utc)
        -- Cardano.toRelativeTime may throw, so we need this guard:
        | utc < t0 = pure Nothing
        | otherwise = pure $ Just $ Cardano.toRelativeTime systemStart utc

    systemStart = Cardano.SystemStart t0

-- -----------------------------------------------------------------------------
-- Legacy functions
-- These only work for a single era. We need to stop using them

-- | The essential parameters necessary for performing slot arithmetic.
data SlotParameters = SlotParameters
    { getEpochLength
        :: EpochLength
    , getSlotLength
        :: SlotLength
    , getGenesisBlockDate
        :: StartTime
    , getActiveSlotCoefficient
        :: ActiveSlotCoefficient
    } deriving (Eq, Generic, Show)

slotParams :: GenesisParameters -> SlotParameters
slotParams gp = SlotParameters
    (gp ^. #getEpochLength)
    (gp ^. #getSlotLength)
    (gp ^. #getGenesisBlockDate)
    (gp ^. #getActiveSlotCoefficient)

-- | Calculate the time at which an epoch begins.
epochStartTime :: SlotParameters -> EpochNo -> UTCTime
epochStartTime sps e = slotStartTime sps $ SlotId e 0

-- | Return the epoch immediately before the given epoch, or 'Nothing' if there
--   is no representable epoch before the given epoch.
epochPred :: EpochNo -> Maybe EpochNo
epochPred (EpochNo e)
    | e == minBound = Nothing
    | otherwise = Just $ EpochNo $ pred e

-- | Return the epoch immediately after the given epoch, or 'Nothing' if there
--   is no representable epoch after the given epoch.
epochSucc :: EpochNo -> Maybe EpochNo
epochSucc (EpochNo e)
    | e == maxBound = Nothing
    | otherwise = Just $ EpochNo $ succ e

-- | Convert a 'SlotId' to the number of slots since genesis.
flatSlot :: EpochLength -> SlotId -> Word64
flatSlot (EpochLength epochLength) (SlotId (EpochNo e) (SlotInEpoch s)) =
    fromIntegral epochLength * fromIntegral e + fromIntegral s

-- | Convert a 'flatSlot' index to 'SlotId'.
--
-- This function will fail if applied to a value that is higher than the maximum
-- value of 'flatSlot' for the specified 'EpochLength'.
--
fromFlatSlot :: EpochLength -> Word64 -> SlotId
fromFlatSlot el@(EpochLength epochLength) n
    | n <= maxFlatSlot =
        SlotId (EpochNo $ fromIntegral e) (fromIntegral s)
    | otherwise =
        error $ mconcat
            [ "fromFlatSlot: The specified flat slot number ("
            , show n
            , ") is higher than the maximum flat slot number ("
            , show maxFlatSlot
            , ") for the specified epoch length ("
            , show epochLength
            , ")."
            ]
  where
    e = n `div` fromIntegral epochLength
    s = n `mod` fromIntegral epochLength
    maxFlatSlot =
        flatSlot el (SlotId (EpochNo maxBound) (SlotInEpoch $ epochLength - 1))

-- | @slotDifference a b@ is how many slots @a@ is after @b@. The result is
-- non-negative, and if @b > a@ then this function returns zero.
slotDifference :: SlotParameters -> SlotId -> SlotId -> Quantity "slot" Natural
slotDifference (SlotParameters el _ _ _) a b
    | a' > b' = Quantity $ fromIntegral $ a' - b'
    | otherwise = Quantity 0
  where
    a' = flatSlot el a
    b' = flatSlot el b

-- | Return the slot immediately before the given slot.
slotPred :: SlotParameters -> SlotId -> Maybe SlotId
slotPred (SlotParameters (EpochLength el) _ _ _) (SlotId en sn)
    | en == 0 && sn == 0 = Nothing
    | sn > 0 = Just $ SlotId en (sn - 1)
    | otherwise = Just $ SlotId (en - 1) (SlotInEpoch $ el - 1)

-- | Return the slot immediately after the given slot.
slotSucc :: SlotParameters -> SlotId -> SlotId
slotSucc (SlotParameters (EpochLength el) _ _ _) (SlotId en (SlotInEpoch sn))
    | sn < el - 1 = SlotId en (SlotInEpoch $ sn + 1)
    | otherwise = SlotId (en + 1) 0

-- | The time when a slot begins.
slotStartTime :: SlotParameters -> SlotId -> UTCTime
slotStartTime (SlotParameters el (SlotLength sl) (StartTime st) _) slot =
    addUTCTime offset st
  where
    offset = sl * fromIntegral (flatSlot el slot)

-- | For the given time 't', determine the ID of the earliest slot with start
--   time 's' such that 't ≤ s'.
slotCeiling :: SlotParameters -> UTCTime -> SlotId
slotCeiling sp@(SlotParameters _ (SlotLength sl) _ _) t =
    fromMaybe slotMinBound $ slotAt' sp (addUTCTime (pred sl) t)

-- | For the given time 't', determine the ID of the latest slot with start
--   time 's' such that 's ≤ t'.
slotFloor :: SlotParameters -> UTCTime -> Maybe SlotId
slotFloor = slotAt'

-- | Returns the earliest slot.
slotMinBound :: SlotId
slotMinBound = SlotId 0 0

-- | For the given time 't', determine the ID of the unique slot with start
--   time 's' and end time 'e' such that 's ≤ t ≤ e'.
slotAt' :: SlotParameters -> UTCTime -> Maybe SlotId
slotAt' (SlotParameters (EpochLength el) (SlotLength sl) (StartTime st) _) t
    | t < st = Nothing
    | otherwise = Just $ SlotId {epochNumber, slotNumber}
  where
    diff :: NominalDiffTime
    diff = t `diffUTCTime` st

    epochLength :: NominalDiffTime
    epochLength = fromIntegral el * sl

    epochNumber = EpochNo $
        floor (diff / epochLength)

    slotNumber = SlotInEpoch $
        floor ((diff - fromIntegral (unEpochNo epochNumber) * epochLength) / sl)

-- | Transforms the given inclusive time range into an inclusive slot range.
--
-- This function returns a slot range if (and only if) the specified time range
-- intersects with the life of the blockchain.
--
-- If, on the other hand, the specified time range terminates before the start
-- of the blockchain, this function returns 'Nothing'.
--
slotRangeFromTimeRange'
    :: SlotParameters
    -> Range UTCTime
    -> Maybe (Range SlotId)
slotRangeFromTimeRange' sps (Range mStart mEnd) =
    Range slotStart <$> slotEnd
  where
    slotStart =
        slotCeiling sps <$> mStart
    slotEnd =
        maybe (Just Nothing) (fmap Just . slotFloor sps) mEnd
