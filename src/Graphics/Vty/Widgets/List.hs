{-# LANGUAGE DeriveDataTypeable #-}
-- |This module provides a 'List' widget for rendering a list of
-- arbitrary widgets.  A 'List' has the following features:
--
-- * A style for the list elements
--
-- * A styled cursor indicating which element is selected
--
-- * A /window size/ indicating how many elements should be visible to
--   the user
--
-- * An internal pointer to the start of the visible window, which
--   automatically shifts as the list is scrolled
module Graphics.Vty.Widgets.List
    ( List
    , ListItem
    , ListError(..)
    -- ** List creation
    , mkList
    , mkSimpleList
    , listWidget
    , addToList
    , removeFromList
    , getListSize
    -- ** List manipulation
    , scrollBy
    , scrollUp
    , scrollDown
    , pageUp
    , pageDown
    , resize
    , onSelectionChange
    , onItemAdded
    , onItemRemoved
    -- ** List inspection
    , listItems
    , getSelected
    , scrollTopIndex
    , scrollWindowSize
    , getVisibleItems
    )
where

import Data.Typeable
    ( Typeable
    )
import Data.Maybe
    ( catMaybes
    )
import Control.Exception
    ( Exception
    , throw
    )
import Control.Monad
    ( when
    )
import Control.Monad.Trans
    ( MonadIO
    , liftIO
    )
import Graphics.Vty
    ( Attr
    , DisplayRegion(..)
    , Image
    , Key(..)
    , Modifier
    , (<|>)
    , image_width
    , vert_cat
    , image_height
    , char_fill
    , def_attr
    )
import Graphics.Vty.Widgets.Core
    ( WidgetImpl(..)
    , Widget
    , (<~)
    , (<~~)
    , render
    , newWidget
    , updateWidget
    , updateWidgetState
    , getState
    , getPhysicalPosition
    , getPhysicalSize
    , withWidth
    , withHeight
    , growVertical
    )
import Graphics.Vty.Widgets.Text
    ( FormattedText
    , simpleText
    )

data ListError = BadItemIndex Int
               | ResizeError
               | BadListWidgetSizePolicy
                 deriving (Show, Typeable)

instance Exception ListError

-- |A list item. Each item contains an arbitrary internal identifier
-- @a@ and a 'Widget' representing it.
type ListItem a b = (a, Widget b)

-- |The list widget type.  Lists are parameterized over the /internal/
-- /identifier type/ @a@, the type of internal identifiers used to
-- refer to the visible representations of the list contents, and the
-- /widget type/ @b@, the type of widgets used to represent the list
-- visually.
data List a b = List { normalAttr :: Maybe Attr
                     , selectedAttr :: Attr
                     , selectedIndex :: Int
                     -- ^The currently selected list index.
                     , scrollTopIndex :: Int
                     -- ^The start index of the window of visible list
                     -- items.
                     , scrollWindowSize :: Int
                     -- ^The size of the window of visible list items.
                     , listItems :: [ListItem a b]
                     -- ^The items in the list.
                     , selectionChangeHandler :: Widget (List a b) -> Int -> a -> Widget b -> IO ()
                     , itemAddHandler :: Widget (List a b) -> Int -> a -> Widget b -> IO ()
                     , itemRemoveHandler :: Widget (List a b) -> Int -> a -> Widget b -> IO ()
                     , itemHeight :: Int
                     , itemConstructor :: a -> IO (Widget b)
                     -- ^Function to construct new items
                     }

-- |Create a new list.  Emtpy lists and empty scrolling windows are
-- not allowed.
mkList :: Attr -- ^The attribute of the selected item
       -> (a -> IO (Widget b)) -- ^Constructor for new item widgets
       -> List a b
mkList selAttr f =
    List { normalAttr = Nothing
         , selectedAttr = selAttr
         , selectedIndex = -1
         , scrollTopIndex = 0
         , scrollWindowSize = 0
         , listItems = []
         , selectionChangeHandler = \_ _ _ _ -> return ()
         , itemAddHandler = \_ _ _ _ -> return ()
         , itemRemoveHandler = \_ _ _ _ -> return ()
         , itemHeight = 0
         , itemConstructor = f
         }

getListSize :: (MonadIO m) => Widget (List a b) -> m Int
getListSize = ((length . listItems) <~~)

removeFromList :: (MonadIO m) => Widget (List a b) -> Int -> m (ListItem a b)
removeFromList list pos = do
  st <- getState list

  let numItems = length $ listItems st

  when (pos < 0 || pos >= numItems) $
       throw $ BadItemIndex pos

  -- Get the item from the list.
  let (label, w) = listItems st !! pos
      sel = selectedIndex st

  -- If that item is currently selected, select a different item.
      newSelectedIndex = if pos > sel
                         then pos
                         else if pos < sel
                              then if sel == 0
                                   then 0
                                   else sel - 1
                              else if sel == 0
                                   then if numItems == 1
                                        then (-1)
                                        else 0
                                   else if sel == numItems - 1
                                        then sel - 1
                                        else sel

  updateWidgetState list $ \s -> s { selectedIndex = newSelectedIndex
                                   , listItems = take pos (listItems st) ++
                                                 drop (pos + 1) (listItems st)
                                   }

  -- Notify the removal handler.
  notifyItemRemoveHandler list pos label w

  -- Notify the selection handler, but only if the position we deleted
  -- from is the selected position; that means the selection changed.
  when (pos <= selectedIndex st) $
       notifySelectionHandler list

  -- Return the removed item.
  return (label, w)

addToList :: (MonadIO m) => Widget (List a b) -> a -> m ()
addToList list key = do
  numItems <- (length . listItems) <~~ list

  makeWidget <- itemConstructor <~~ list
  w <- liftIO $ makeWidget key

  v <- growVertical w
  when (v) $ throw BadListWidgetSizePolicy

  h <- case numItems of
         0 -> do
           -- We're adding the first element to the list, so we need
           -- to compute the item height based on this widget.  We
           -- just render it in an unreasonably large space (since,
           -- really, list items should never be THAT big) and measure
           -- the result, assuming that all list widgets will have the
           -- same size.  If you violate this, you'll have interesting
           -- results!
           img <- render w (DisplayRegion 100 100) def_attr Nothing
           return $ fromEnum $ image_height img
         _ -> itemHeight <~~ list

  updateWidgetState list $ \s -> s { itemHeight = h
                                   , listItems = listItems s ++ [(key, w)]
                                   , selectedIndex = if numItems == 0
                                                     then 0
                                                     else selectedIndex s
                                   }

  notifyItemAddHandler list (numItems + 1) key w

  when (numItems == 0) $
       notifySelectionHandler list

onSelectionChange :: (MonadIO m) =>
                     Widget (List a b)
                  -> (Widget (List a b) -> Int -> a -> Widget b -> IO ())
                  -> m ()
onSelectionChange wRef handler = do
  oldHandler <- selectionChangeHandler <~~ wRef

  let combinedHandler =
          \w pos k ch -> do
            oldHandler w pos k ch
            handler w pos k ch

  updateWidgetState wRef $ \s -> s { selectionChangeHandler = combinedHandler }

onItemAdded :: (MonadIO m) => Widget (List a b)
            -> (Widget (List a b) -> Int -> a -> Widget b -> IO ()) -> m ()
onItemAdded wRef handler = do
  oldHandler <- itemAddHandler <~~ wRef

  let combinedHandler =
          \w pos k iw -> do
            oldHandler w pos k iw
            handler w pos k iw

  updateWidgetState wRef $ \s -> s { itemAddHandler = combinedHandler }

onItemRemoved :: (MonadIO m) => Widget (List a b)
            -> (Widget (List a b) -> Int -> a -> Widget b -> IO ()) -> m ()
onItemRemoved wRef handler = do
  oldHandler <- itemRemoveHandler <~~ wRef

  let combinedHandler =
          \w pos k iw -> do
            oldHandler w pos k iw
            handler w pos k iw

  updateWidgetState wRef $ \s -> s { itemRemoveHandler = combinedHandler }

listWidget :: (MonadIO m) => List a b -> m (Widget (List a b))
listWidget list = do
  wRef <- newWidget
  updateWidget wRef $ \w ->
      w { state = list
        , getGrowHorizontal = return False
        , getGrowVertical = return True

        -- XXX it might be crazy, but we could even pass events we
        -- don't handle onto the currently selected widget!
        , keyEventHandler = listKeyEvent

        , cursorInfo =
            \this -> do
              st <- getState this
              pos <- getPhysicalPosition this
              sz <- getPhysicalSize this
              let newCol = max 0 (region_width pos + region_width sz - 1)
                  newRow = region_height pos + toEnum (max 0 $ selectedIndex st - scrollTopIndex st)
              return $ Just (pos `withWidth` newCol `withHeight` newRow)

        , draw =
            \this sz defAttr mAttr -> do
              h <- itemHeight <~~ this

              -- Resize the list based on the available space and the
              -- height of each item.
              when (h > 0) $
                   resize (max 1 ((fromEnum $ region_height sz) `div` h)) this

              listData <- getState this
              renderListWidget listData sz defAttr mAttr

        -- XXX!!! define setPosition to set position of visible
        -- widgets in list
        }
  return wRef

listKeyEvent :: Widget (List a b) -> Key -> [Modifier] -> IO Bool
listKeyEvent w KUp _ = scrollUp w >> return True
listKeyEvent w KDown _ = scrollDown w >> return True
listKeyEvent w KPageUp _ = pageUp w >> return True
listKeyEvent w KPageDown _ = pageDown w >> return True
listKeyEvent _ _ _ = return False

renderListWidget :: List a b -> DisplayRegion -> Attr -> Maybe Attr -> IO Image
renderListWidget list s defAttr mAttr = do
  let items = map (\((_, w), sel) -> (w, sel)) $ getVisibleItems_ list

      renderVisible [] = return []
      renderVisible ((w, sel):ws) = do
        let att = if sel
                  then (selectedAttr list)
                  else head $ catMaybes [ mAttr
                                        , normalAttr list
                                        , Just defAttr
                                        ]
        img <- render w s defAttr $ Just att

        let actualHeight = min (region_height s) (toEnum $ itemHeight list)
            img' = img <|> char_fill att ' '
                   (region_width s - image_width img)
                   actualHeight
        imgs <- renderVisible ws
        return (img':imgs)

  -- XXX this is probably incorrect for widgets with height > 1
  let filler = char_fill attr ' ' (region_width s) fill_height
      fill_height = if scrollWindowSize list == 0
                    then region_height s
                    else toEnum $ scrollWindowSize list - length items
      attr = head $ catMaybes [ mAttr, normalAttr list, Just defAttr ]

  visible_imgs <- renderVisible items

  return $ vert_cat (visible_imgs ++ [filler])

-- |A convenience function to create a new list using 'String's as the
-- internal identifiers and 'Text' widgets to represent those strings.
mkSimpleList :: (MonadIO m) =>
                Attr -- ^The attribute of the selected item
             -> [String] -- ^The list items
             -> m (Widget (List String FormattedText))
mkSimpleList selAttr labels = do
  list <- listWidget $ mkList selAttr (simpleText def_attr)
  mapM_ (addToList list) labels
  return list

-- note that !! here will always succeed because selectedIndex will
-- never be out of bounds and the list will always be non-empty.
-- |Get the currently selected list item.
getSelected :: (MonadIO m) => Widget (List a b) -> m (Maybe (Int, ListItem a b))
getSelected wRef = do
  list <- state <~ wRef
  case selectedIndex list of
    (-1) -> return Nothing
    i -> return $ Just (i, (listItems list) !! i)

-- |Set the window size of the list.  This automatically adjusts the
-- window position to keep the selected item visible.
resize :: (MonadIO m) => Int -> Widget (List a b) -> m ()
resize newSize wRef = do
  when (newSize == 0) $ throw ResizeError

  size <- (scrollWindowSize . state) <~ wRef

  case compare newSize size of
    EQ -> return () -- Do nothing if the window size isn't changing.
    GT -> updateWidgetState wRef $ \list ->
          list { scrollWindowSize = newSize
               , scrollTopIndex = max 0 (scrollTopIndex list - (newSize - scrollWindowSize list))
               }
    -- Otherwise it's smaller, so we need to look at which item is
    -- selected and decide whether to change the scrollTopIndex.
    LT -> do
      list <- state <~ wRef

      -- If the currently selected item would be out of view in the
      -- new size, then we need to move the display top down to keep
      -- it visible.
      let newBottomPosition = scrollTopIndex list + newSize - 1
          current = selectedIndex list
          newScrollTopIndex = if current > newBottomPosition
                              then current - newSize + 1
                              else scrollTopIndex list

      updateWidgetState wRef $ const $ list { scrollWindowSize = newSize
                                            , scrollTopIndex = newScrollTopIndex
                                            }

-- |Scroll a list up or down by the specified number of positions and
-- return the new scrolled list.  Scrolling by a positive amount
-- scrolls downward and scrolling by a negative amount scrolls upward.
-- This automatically takes care of managing internal list state:
--
-- * Moves the cursor by the specified amount and clamps the cursor
--   position to the beginning or the end of the list where
--   appropriate
--
-- * Moves the scrolling window position if necessary (i.e., if the
--   cursor moves to an item not currently in view)
scrollBy :: (MonadIO m) => Int -> Widget (List a b) -> m ()
scrollBy amount wRef = updateWidgetState wRef $ scrollBy' amount

-- Pure interface; should be used internally to the widget.
scrollBy' :: Int -> List a b -> List a b
scrollBy' amount list =
  let sel = selectedIndex list
      lastPos = (length $ listItems list) - 1
      validPositions = [0..lastPos]
      newPosition = sel + amount

      newSelected = if newPosition `elem` validPositions
                    then newPosition
                    else if newPosition > lastPos
                         then lastPos
                         else 0

      bottomPosition = scrollTopIndex list + scrollWindowSize list - 1
      topPosition = scrollTopIndex list
      windowPositions = [topPosition..bottomPosition]

      adjustedTop = if newPosition `elem` windowPositions
                    then topPosition
                    else if newSelected >= bottomPosition
                         then newSelected - scrollWindowSize list + 1
                         else newSelected

  in if scrollWindowSize list == 0
     then list
     else list { scrollTopIndex = adjustedTop
               , selectedIndex = newSelected }

notifySelectionHandler :: (MonadIO m) => Widget (List a b) -> m ()
notifySelectionHandler wRef = do
  h <- selectionChangeHandler <~~ wRef
  result <- getSelected wRef
  case result of
    Nothing -> return ()
    Just (pos, (k, ch)) -> liftIO $ h wRef pos k ch

notifyItemRemoveHandler :: (MonadIO m) => Widget (List a b) -> Int -> a -> Widget b -> m ()
notifyItemRemoveHandler wRef pos k w = do
  h <- itemRemoveHandler <~~ wRef
  liftIO $ h wRef pos k w

notifyItemAddHandler :: (MonadIO m) => Widget (List a b) -> Int -> a -> Widget b -> m ()
notifyItemAddHandler wRef pos k w = do
  h <- itemAddHandler <~~ wRef
  liftIO $ h wRef pos k w

-- |Scroll a list down by one position.
scrollDown :: (MonadIO m) => Widget (List a b) -> m ()
scrollDown wRef = scrollBy 1 wRef >> notifySelectionHandler wRef

-- |Scroll a list up by one position.
scrollUp :: (MonadIO m) => Widget (List a b) -> m ()
scrollUp wRef = scrollBy (-1) wRef >> notifySelectionHandler wRef

-- |Scroll a list down by one page from the current cursor position.
pageDown :: (MonadIO m) => Widget (List a b) -> m ()
pageDown wRef = do
  amt <- scrollWindowSize <~~ wRef
  scrollBy amt wRef
  notifySelectionHandler wRef

-- |Scroll a list up by one page from the current cursor position.
pageUp :: (MonadIO m) => Widget (List a b) -> m ()
pageUp wRef = do
  amt <- scrollWindowSize <~~ wRef
  scrollBy (-1 * amt) wRef
  notifySelectionHandler wRef

-- |Given a 'List', return the items that are currently visible
-- according to the state of the list.  Returns the visible items and
-- flags indicating whether each is selected.
getVisibleItems :: (MonadIO m) => Widget (List a b) -> m [(ListItem a b, Bool)]
getVisibleItems wRef = do
  list <- state <~ wRef
  return $ getVisibleItems_ list

getVisibleItems_ :: List a b -> [(ListItem a b, Bool)]
getVisibleItems_ list =
    let start = scrollTopIndex list
        stop = scrollTopIndex list + scrollWindowSize list
        adjustedStop = (min stop $ length $ listItems list) - 1
    in [ (listItems list !! i, i == selectedIndex list)
             | i <- [start..adjustedStop] ]