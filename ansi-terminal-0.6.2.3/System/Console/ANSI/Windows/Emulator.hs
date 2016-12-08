module System.Console.ANSI.Windows.Emulator (
#include "Exports-Include.hs"
    ) where

import System.Console.ANSI.Common
import qualified System.Console.ANSI.Unix as Unix
import System.Console.ANSI.Windows.Foreign

import System.IO

import Control.Exception (SomeException, catchJust)
import Control.Monad (guard)

import Data.Bits
import Data.Char (toLower)
import Data.List


#include "Common-Include.hs"


withHandle :: Handle -> (HANDLE -> IO a) -> IO a
withHandle handle action = do
    -- It's VERY IMPORTANT that we flush before issuing any sort of Windows API call to change the console
    -- because on Windows the arrival of API-initiated state changes is not necessarily synchronised with that
    -- of the text they are attempting to modify.
    hFlush handle
    withHandleToHANDLE handle action


-- Unfortunately, the emulator is not perfect. In particular, it has a tendency to die with exceptions about
-- invalid handles when it is used with certain Windows consoles (e.g. mintty, terminator, or cygwin sshd).
--
-- This happens because in those environments the stdout family of handles are not actually associated with
-- a real console.
--
-- My observation is that every time I've seen this in practice, the handle we have instead of the actual console
-- handle is there so that the terminal supports ANSI escape codes. So 99% of the time, the correct thing to do is
-- just to fall back on the Unix module to output the ANSI codes and hope for the best.
emulatorFallback :: IO a -> IO a -> IO a
emulatorFallback fallback first_try = catchJust (\e -> guard (isHandleIsInvalidException e) >> return ()) first_try (\() -> fallback)
  where
    -- NB: this is a pretty hacked-up way to find out if we have the right sort of exception, but System.Win32.Types.fail* call into
    -- the fail :: String -> IO a function, and so we don't get any nice exception object we can extract information from.
    isHandleIsInvalidException :: SomeException -> Bool
    isHandleIsInvalidException e = "the handle is invalid" `isInfixOf` e_string || "invalid handle" `isInfixOf` e_string
      where e_string = map toLower (show e)


adjustCursorPosition :: HANDLE -> (SHORT -> SHORT -> SHORT) -> (SHORT -> SHORT -> SHORT) -> IO ()
adjustCursorPosition handle change_x change_y = do
    screen_buffer_info <- getConsoleScreenBufferInfo handle
    let window = csbi_window screen_buffer_info
        (COORD x y) = csbi_cursor_position screen_buffer_info
        cursor_pos' = COORD (change_x (rect_left window) x) (change_y (rect_top window) y)
    setConsoleCursorPosition handle cursor_pos'

hCursorUp h n       = emulatorFallback (Unix.hCursorUp h n)       $ withHandle h $ \handle -> adjustCursorPosition handle (\_ x -> x) (\_ y -> y - fromIntegral n)
hCursorDown h n     = emulatorFallback (Unix.hCursorDown h n)     $ withHandle h $ \handle -> adjustCursorPosition handle (\_ x -> x) (\_ y -> y + fromIntegral n)
hCursorForward h n  = emulatorFallback (Unix.hCursorForward h n)  $ withHandle h $ \handle -> adjustCursorPosition handle (\_ x -> x + fromIntegral n) (\_ y -> y)
hCursorBackward h n = emulatorFallback (Unix.hCursorBackward h n) $ withHandle h $ \handle -> adjustCursorPosition handle (\_ x -> x - fromIntegral n) (\_ y -> y)

cursorUpCode _       = ""
cursorDownCode _     = ""
cursorForwardCode _  = ""
cursorBackwardCode _ = ""


adjustLine :: HANDLE -> (SHORT -> SHORT -> SHORT) -> IO ()
adjustLine handle change_y = adjustCursorPosition handle (\window_left _ -> window_left) change_y

hCursorDownLine h n = emulatorFallback (Unix.hCursorDownLine h n) $ withHandle h $ \handle -> adjustLine handle (\_ y -> y + fromIntegral n)
hCursorUpLine h n   = emulatorFallback (Unix.hCursorUpLine h n)   $ withHandle h $ \handle -> adjustLine handle (\_ y -> y - fromIntegral n)

cursorDownLineCode _   = ""
cursorUpLineCode _ = ""


hSetCursorColumn h x = emulatorFallback (Unix.hSetCursorColumn h x) $ withHandle h $ \handle -> adjustCursorPosition handle (\window_left _ -> window_left + fromIntegral x) (\_ y -> y)

setCursorColumnCode _ = ""


hSetCursorPosition h y x = emulatorFallback (Unix.hSetCursorPosition h y x) $ withHandle h $ \handle -> adjustCursorPosition handle (\window_left _ -> window_left + fromIntegral x) (\window_top _ -> window_top + fromIntegral y)

setCursorPositionCode _ _ = ""


clearChar :: WCHAR
clearChar = charToWCHAR ' '

clearAttribute :: WORD
clearAttribute = 0

hClearScreenFraction :: HANDLE -> (SMALL_RECT -> COORD -> (DWORD, COORD)) -> IO ()
hClearScreenFraction handle fraction_finder = do
    screen_buffer_info <- getConsoleScreenBufferInfo handle

    let window = csbi_window screen_buffer_info
        cursor_pos = csbi_cursor_position screen_buffer_info
        (fill_length, fill_cursor_pos) = fraction_finder window cursor_pos

    fillConsoleOutputCharacter handle clearChar fill_length fill_cursor_pos
    fillConsoleOutputAttribute handle clearAttribute fill_length fill_cursor_pos
    return ()

hClearFromCursorToScreenEnd h = emulatorFallback (Unix.hClearFromCursorToScreenEnd h) $ withHandle h $ \handle -> hClearScreenFraction handle go
  where
    go window cursor_pos = (fromIntegral fill_length, cursor_pos)
      where
        size_x = rect_width window
        size_y = rect_bottom window - coord_y cursor_pos
        line_remainder = size_x - coord_x cursor_pos
        fill_length = size_x * size_y + line_remainder

hClearFromCursorToScreenBeginning h = emulatorFallback (Unix.hClearFromCursorToScreenBeginning h) $ withHandle h $ \handle -> hClearScreenFraction handle go
  where
    go window cursor_pos = (fromIntegral fill_length, rect_top_left window)
      where
        size_x = rect_width window
        size_y = coord_y cursor_pos - rect_top window
        line_remainder = coord_x cursor_pos
        fill_length = size_x * size_y + line_remainder

hClearScreen h = emulatorFallback (Unix.hClearScreen h) $ withHandle h $ \handle -> hClearScreenFraction handle go
  where
    go window _ = (fromIntegral fill_length, rect_top_left window)
      where
        size_x = rect_width window
        size_y = rect_height window
        fill_length = size_x * size_y

hClearFromCursorToLineEnd h = emulatorFallback (Unix.hClearFromCursorToLineEnd h) $ withHandle h $ \handle -> hClearScreenFraction handle go
  where
    go window cursor_pos = (fromIntegral (rect_right window - coord_x cursor_pos), cursor_pos)

hClearFromCursorToLineBeginning h = emulatorFallback (Unix.hClearFromCursorToLineBeginning h) $ withHandle h $ \handle -> hClearScreenFraction handle go
  where
    go window cursor_pos = (fromIntegral (coord_x cursor_pos), cursor_pos { coord_x = rect_left window })

hClearLine h = emulatorFallback (Unix.hClearLine h) $ withHandle h $ \handle -> hClearScreenFraction handle go
  where
    go window cursor_pos = (fromIntegral (rect_width window), cursor_pos { coord_x = rect_left window })

clearFromCursorToScreenEndCode       = ""
clearFromCursorToScreenBeginningCode = ""
clearScreenCode                      = ""
clearFromCursorToLineEndCode         = ""
clearFromCursorToLineBeginningCode   = ""
clearLineCode                        = ""


hScrollPage :: HANDLE -> Int -> IO ()
hScrollPage handle new_origin_y = do
    screen_buffer_info <- getConsoleScreenBufferInfo handle
    let fill = CHAR_INFO clearChar clearAttribute
        window = csbi_window screen_buffer_info
        origin = COORD (rect_left window) (rect_top window + fromIntegral new_origin_y)
    scrollConsoleScreenBuffer handle window Nothing origin fill

hScrollPageUp   h n = emulatorFallback (Unix.hScrollPageUp   h n) $ withHandle h $ \handle -> hScrollPage handle (negate n)
hScrollPageDown h n = emulatorFallback (Unix.hScrollPageDown h n) $ withHandle h $ \handle -> hScrollPage handle n

scrollPageUpCode _   = ""
scrollPageDownCode _ = ""


{-# INLINE applyANSIColorToAttribute #-}
applyANSIColorToAttribute :: WORD -> WORD -> WORD -> Color -> WORD -> WORD
applyANSIColorToAttribute rED gREEN bLUE color attribute = case color of
    Black   -> attribute'
    Red     -> attribute' .|. rED
    Green   -> attribute' .|. gREEN
    Yellow  -> attribute' .|. rED .|. gREEN
    Blue    -> attribute' .|. bLUE
    Magenta -> attribute' .|. rED .|. bLUE
    Cyan    -> attribute' .|. gREEN .|. bLUE
    White   -> attribute' .|. wHITE
  where
    wHITE = rED .|. gREEN .|. bLUE
    attribute' = attribute .&. (complement wHITE)

applyForegroundANSIColorToAttribute, applyBackgroundANSIColorToAttribute :: Color -> WORD -> WORD
applyForegroundANSIColorToAttribute = applyANSIColorToAttribute fOREGROUND_RED fOREGROUND_GREEN fOREGROUND_BLUE
applyBackgroundANSIColorToAttribute = applyANSIColorToAttribute bACKGROUND_RED bACKGROUND_GREEN bACKGROUND_BLUE

swapForegroundBackgroundColors :: WORD -> WORD
swapForegroundBackgroundColors attribute = clean_attribute .|. foreground_attribute' .|. background_attribute'
  where
    foreground_attribute = attribute .&. fOREGROUND_INTENSE_WHITE
    background_attribute = attribute .&. bACKGROUND_INTENSE_WHITE
    clean_attribute = attribute .&. complement (fOREGROUND_INTENSE_WHITE .|. bACKGROUND_INTENSE_WHITE)
    foreground_attribute' = background_attribute `shiftR` 4
    background_attribute' = foreground_attribute `shiftL` 4

applyANSISGRToAttribute :: SGR -> WORD -> WORD
applyANSISGRToAttribute sgr attribute = case sgr of
    Reset -> fOREGROUND_WHITE
    SetConsoleIntensity intensity -> case intensity of
        BoldIntensity   -> attribute .|. iNTENSITY
        FaintIntensity  -> attribute .&. (complement iNTENSITY) -- Not supported
        NormalIntensity -> attribute .&. (complement iNTENSITY)
    SetItalicized _ -> attribute -- Not supported
    SetUnderlining underlining -> case underlining of
        NoUnderline -> attribute .&. (complement cOMMON_LVB_UNDERSCORE)
        _           -> attribute .|. cOMMON_LVB_UNDERSCORE -- Not supported, since cOMMON_LVB_UNDERSCORE seems to have no effect
    SetBlinkSpeed _ -> attribute -- Not supported
    SetVisible _    -> attribute -- Not supported
    -- The cOMMON_LVB_REVERSE_VIDEO doesn't actually appear to have any affect on the colors being displayed, so the emulator
    -- just uses it to carry information and implements the color-swapping behaviour itself. Bit of a hack, I guess :-)
    SetSwapForegroundBackground True ->
        -- Check if the color-swapping flag is already set
        if attribute .&. cOMMON_LVB_REVERSE_VIDEO /= 0
         then attribute
         else swapForegroundBackgroundColors attribute .|. cOMMON_LVB_REVERSE_VIDEO
    SetSwapForegroundBackground False ->
        -- Check if the color-swapping flag is already not set
        if attribute .&. cOMMON_LVB_REVERSE_VIDEO == 0
         then attribute
         else swapForegroundBackgroundColors attribute .&. (complement cOMMON_LVB_REVERSE_VIDEO)
    SetColor Foreground Dull color  -> applyForegroundANSIColorToAttribute color (attribute .&. (complement fOREGROUND_INTENSITY))
    SetColor Foreground Vivid color -> applyForegroundANSIColorToAttribute color (attribute .|. fOREGROUND_INTENSITY)
    SetColor Background Dull color  -> applyBackgroundANSIColorToAttribute color (attribute .&. (complement bACKGROUND_INTENSITY))
    SetColor Background Vivid color -> applyBackgroundANSIColorToAttribute color (attribute .|. bACKGROUND_INTENSITY)
  where
    iNTENSITY = fOREGROUND_INTENSITY

hSetSGR h sgr = emulatorFallback (Unix.hSetSGR h sgr) $ withHandle h $ \handle -> do
    screen_buffer_info <- getConsoleScreenBufferInfo handle
    let attribute = csbi_attributes screen_buffer_info
        attribute' = foldl' (flip applyANSISGRToAttribute) attribute
          -- make [] equivalent to [Reset], as documented
          (if null sgr then [Reset] else sgr)
    setConsoleTextAttribute handle attribute'

setSGRCode _ = ""


hChangeCursorVisibility :: HANDLE -> Bool -> IO ()
hChangeCursorVisibility handle cursor_visible = do
    cursor_info <- getConsoleCursorInfo handle
    setConsoleCursorInfo handle (cursor_info { cci_cursor_visible = cursor_visible })

hHideCursor h = emulatorFallback (Unix.hHideCursor h) $ withHandle h $ \handle -> hChangeCursorVisibility handle False
hShowCursor h = emulatorFallback (Unix.hShowCursor h) $ withHandle h $ \handle -> hChangeCursorVisibility handle True

hideCursorCode = ""
showCursorCode = ""


-- Windows only supports setting the terminal title on a process-wide basis, so for now we will
-- assume that that is what the user intended. This will fail if they are sending the command
-- over e.g. a network link... but that's not really what I'm designing for.
hSetTitle h title = emulatorFallback (Unix.hSetTitle h title) $ withTString title $ setConsoleTitle

setTitleCode _ = ""
