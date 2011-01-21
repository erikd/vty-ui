{-# LANGUAGE ExistentialQuantification #-}
module Graphics.Vty.Widgets.Padding
    ( Padded
    , Padding
    , Paddable(..)
    , (+++)
    , padded
    , padNone
    , padLeft
    , padRight
    , padTop
    , padBottom
    , padLeftRight
    , padTopBottom
    , padAll
    )
where

import Data.Word
    ( Word
    )
import Data.Monoid
    ( Monoid(..)
    )
import Control.Monad.Trans
    ( MonadIO
    )
import Control.Monad.Reader
    ( ask
    )
import Graphics.Vty
    ( (<->)
    , (<|>)
    , char_fill
    , def_attr
    , image_width
    , image_height
    , region_width
    , region_height
    )
import Graphics.Vty.Widgets.Core
    ( Widget
    , WidgetImpl(..)
    , newWidget
    , updateWidget
    , growVertical
    , growHorizontal
    , handleKeyEvent
    , getState
    , withWidth
    , withHeight
    , render
    , setPhysicalPosition
    )

-- Top, right, bottom, left.
data Padding = Padding Int Int Int Int

data Padded = forall a. Padded (Widget a) Padding

instance Monoid Padding where
    mempty = Padding 0 0 0 0
    mappend (Padding a1 a2 a3 a4) (Padding b1 b2 b3 b4) =
        Padding (a1 + b1) (a2 + b2) (a3 + b3) (a4 + b4)

(+++) :: (Monoid a) => a -> a -> a
(+++) = mappend

class Paddable a where
    pad :: a -> Padding -> a

instance Paddable Padding where
    pad p1 p2 = p1 +++ p2

leftPadding :: Padding -> Word
leftPadding (Padding _ _ _ l) = toEnum l

rightPadding :: Padding -> Word
rightPadding (Padding _ r _ _) = toEnum r

bottomPadding :: Padding -> Word
bottomPadding (Padding _ _ b _) = toEnum b

topPadding :: Padding -> Word
topPadding (Padding t _ _ _) = toEnum t

-- Padding constructors
padNone :: Padding
padNone = Padding 0 0 0 0

padLeft :: Int -> Padding
padLeft v = Padding 0 0 0 v

padRight :: Int -> Padding
padRight v = Padding 0 v 0 0

padTop :: Int -> Padding
padTop v = Padding v 0 0 0

padBottom :: Int -> Padding
padBottom v = Padding 0 0 v 0

padAll :: Int -> Padding
padAll v = Padding v v v v

padTopBottom :: Int -> Padding
padTopBottom v = Padding v 0 v 0

padLeftRight :: Int -> Padding
padLeftRight v = Padding 0 v 0 v

padded :: (MonadIO m) => Widget a -> Padding -> m (Widget Padded)
padded ch padding = do
  wRef <- newWidget
  updateWidget wRef $ \w ->
      w { state = Padded ch padding

        , getGrowVertical = do
            Padded child _ <- ask
            growVertical child

        , getGrowHorizontal = do
            Padded child _ <- ask
            growHorizontal child

        , keyEventHandler =
            \this key mods -> do
              Padded child _ <- getState this
              handleKeyEvent child key mods

        , draw =
            \this sz mAttr ->
                do
                  Padded child p <- getState this

                  -- Compute constrained space based on padding
                  -- settings.
                  let constrained = sz `withWidth` (region_width sz - (leftPadding p + rightPadding p))
                                    `withHeight` (region_height sz - (topPadding p + bottomPadding p))
                      attr = maybe def_attr id mAttr

                  -- Render child.
                  img <- render child constrained mAttr

                  -- Create padding images.
                  let leftImg = char_fill attr ' ' (leftPadding p) (image_height img)
                      rightImg = char_fill attr ' ' (rightPadding p) (image_height img)
                      topImg = char_fill attr ' ' (image_width img + leftPadding p + rightPadding p) (topPadding p)
                      bottomImg = char_fill attr ' ' (image_width img + leftPadding p + rightPadding p) (bottomPadding p)

                  return $ topImg <-> (leftImg <|> img <|> rightImg) <-> bottomImg

        , setPosition =
            \this pos -> do
              Padded child p <- getState this

              -- Considering left and top padding, adjust position and
              -- set on child.
              let newPos = pos
                           `withWidth` (region_width pos + leftPadding p)
                           `withHeight` (region_height pos + topPadding p)

              setPhysicalPosition child newPos

        }
  return wRef