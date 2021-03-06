{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE ConstraintKinds      #-}

module Main (main) where

import qualified Graphics.UI.SDL as SDL
import qualified Graphics.UI.SDL.Image as Image
import Graphics.UI.SDL.Types
import Control.Monad.State hiding (state)
import Control.Monad.Except
import Data.Bits
import Foreign.C.String
import Foreign.C.Types
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils
import Foreign.Ptr
import Foreign.Storable
import GHC.Word
import Shared.DrawingSimple
import Shared.Geometry
import Shared.Input
import Shared.Lifecycle
import Shared.Polling
import Shared.Utilities
import Shared.State


---- Config ----

title :: String
title = "lesson14"

screenWidth :: CInt
screenWidth = 640

screenHeight :: CInt
screenHeight = 480

initialState :: World
initialState = World { appState = Running, frame = 0 }


data AppState = Running | Exiting deriving Eq
data World = World { appState :: AppState, frame :: Int }


---- Application ----

main :: IO ()
main = withSDLContext $ \renderer ->
    withAssets renderer ["./assets/walk.png"] $ \assets -> do
        let inputSource = pollEvent `into` updateState
        let pollDraw = inputSource ~>~ drawState renderer assets
        runStateT (repeatUntilComplete pollDraw) initialState


fullWindow :: SDL.Rect
fullWindow = toRect 0 0 screenWidth screenHeight


drawState :: SDL.Renderer -> [Asset] -> World -> IO ()
drawState renderer assets (World Running frameValue) = withBlankScreen renderer $ do
    let currentFrame = getFrameAtTime frameValue
    let ImageAsset texture' = head assets
    let spriteRect = toRect 0 0 192 (192 :: Int)

    with2 (getMask currentFrame) (spriteRect `centredOn` fullWindow) (SDL.renderCopy renderer texture')

    where getMask :: Int -> SDL.Rect
          getMask x = toRect (x * 48) 0 48 48
          frameCount = 8
          getFrameAtTime t = 8 `stepsPerSecond` t `mod` frameCount

drawState _ _ _ = return ()


stepsPerSecond :: Int -> Int -> Int
stepsPerSecond ms s = (s * ms) `div` 60


withBlankScreen :: SDL.Renderer -> IO a -> IO ()
withBlankScreen renderer operation = do
    _ <- SDL.setRenderDrawColor renderer 0xFF 0xFF 0xFF 0xFF
    _ <- SDL.renderClear renderer
    _ <- operation
    SDL.renderPresent renderer


updateState :: Input -> World -> World
updateState (Just (SDL.QuitEvent _ _)) state = state { appState = Exiting }
updateState _ state = state { frame = frame state + 1 }


repeatUntilComplete :: (Monad m) => m World -> m ()
repeatUntilComplete game = game >>= \world -> unless (appState world == Exiting) $ repeatUntilComplete game


---- Initialization ----

type SDLInitFlags = Word32
type SDLImageFlags = Image.InitFlag

data SDLHintKey = RenderScaleQuality

instance Show SDLHintKey where
    show RenderScaleQuality = "SDL_RENDER_SCALE_QUALITY"


class SDLHintValue a where
    toString :: a -> String

data RenderScaleQualityValue = Nearest | Linear | Best

instance SDLHintValue RenderScaleQualityValue where
    toString Nearest = "0"
    toString Linear = "1"
    toString Best = "2"

data Asset = ImageAsset SDL.Texture


withSDLContext :: (SDL.Renderer -> IO a) -> IO ()
withSDLContext renderOperation = do
    setupResult <- runExceptT $ do
        initializeSDL [SDL.SDL_INIT_VIDEO]
        Image.imgInit [Image.InitPNG]
        setHint RenderScaleQuality Nearest

        window <- createWindow title
        renderer <- createRenderer window (-1) [SDL.SDL_RENDERER_ACCELERATED, SDL.SDL_RENDERER_PRESENTVSYNC]
        return (window, renderer)

    sdlCleanup setupResult renderOperation


sdlCleanup :: Either SDLError (SDL.Window, SDL.Renderer) -> (SDL.Renderer -> IO a) -> IO ()
sdlCleanup (Left someError) _ = handleNoInputSDLError error someError
sdlCleanup (Right (window, renderer)) renderOperation = do
    _ <- renderOperation renderer
    SDL.destroyRenderer renderer
    SDL.destroyWindow window
    SDL.quit
    Image.imgQuit


initializeSDL' :: [Word32] -> SDLRisky ()
initializeSDL' flags = do
    result <- liftIO (SDL.init $ foldl (.|.) 0 flags)
    when (result < 0) $ throwSDLError (SDLInitError "SDL")


initializeSDL :: [Word32] -> SDLRisky ()
initializeSDL flags =
    liftIO (SDL.init $ foldl (.|.) 0 flags) >>=
    void . checkForSDLError (SDLInitError "SDL")


class    SDLResult a       where checkForSDLError :: SDLError -> a -> SDLRisky a
instance SDLResult CInt    where checkForSDLError = throwSDLErrorIf (< 0)
instance SDLResult (Ptr a) where checkForSDLError = throwSDLErrorIf (== nullPtr)
instance SDLResult Bool    where checkForSDLError = throwSDLErrorIf not


throwSDLErrorIf :: (a -> Bool) -> SDLError -> a -> SDLRisky a
throwSDLErrorIf isError e result = if isError result
    then throwSDLError e
    else return result

createWindow :: String -> SDLRisky SDL.Window
createWindow windowTitle = do
    window <- liftIO $ withCAString windowTitle $ \title ->
        SDL.createWindow
            title
            SDL.SDL_WINDOWPOS_UNDEFINED
            SDL.SDL_WINDOWPOS_UNDEFINED
            screenWidth
            screenHeight
            SDL.SDL_WINDOW_SHOWN

    if window == nullPtr
        then throwSDLError WindowError
        else return window


createRenderer :: SDL.Window -> CInt -> [Word32] -> SDLRisky SDL.Renderer
createRenderer window index flags = do
    renderer <- liftIO $ SDL.createRenderer window index $ foldl (.|.) 0 flags
    if renderer == nullPtr
        then throwSDLError RendererError
        else return renderer


withAssets :: SDL.Renderer -> [FilePath] -> ([Asset] -> IO a) -> IO ()
withAssets renderer paths f = do
    maybeAssets <- runExceptT $ mapM (loadTexture renderer) paths
    cleanupAssets maybeAssets f


cleanupAssets :: Either SDLError [Asset] -> ([Asset] -> IO a) -> IO ()
cleanupAssets (Left someError) _ = handleNoInputSDLError error someError
cleanupAssets (Right assets) f = f assets >> mapM_ freeAsset assets


freeAsset :: Asset -> IO ()
freeAsset (ImageAsset tex) = SDL.destroyTexture tex


---- Surfacing & Texture Loading ----

loadSurface :: String -> SDLRisky (Ptr SDL.Surface)
loadSurface path = do
    surface <- liftIO $ withCAString path Image.load
    if surface == nullPtr
        then throwSDLError (SurfaceError path)
        else return surface


loadTexture :: SDL.Renderer -> String -> SDLRisky Asset
loadTexture renderer path = do
    loadedSurface <- loadSurface path
    let applyToSurface = flip applyToPointer loadedSurface

    pixelFormat <- liftIO $ applyToSurface SDL.surfaceFormat
    key <- liftIO $ SDL.mapRGB pixelFormat 0 0xFF 0xFF

    _ <- liftIO $ SDL.setColorKey loadedSurface 1 key
    newTexture <- createTextureFromSurface renderer loadedSurface

    liftIO $ SDL.freeSurface loadedSurface
    if newTexture == nullPtr
        then throwSDLError TextureError
        else return (ImageAsset newTexture)


createTextureFromSurface :: SDL.Renderer -> Ptr SDL.Surface -> SDLRisky Texture
createTextureFromSurface renderer surface = do
    result <- liftIO $ SDL.createTextureFromSurface renderer surface
    if result == nullPtr
        then throwSDLError TextureError
        else return result


renderTexture :: SDL.Renderer -> SDL.Texture -> SDL.Rect -> SDL.Rect -> IO CInt
renderTexture renderer texture renderMask renderQuad = with2 renderMask renderQuad $ SDL.renderCopy renderer texture


---- Error Handling ----

type SDLRisky = ExceptT SDLError IO
data SDLError = SDLInitError String
              | SetHintError String
              | WindowError
              | RendererError
              | SurfaceError String
              | TextureError


handleNoInputSDLError :: (MonadIO m) => (String -> IO a) -> SDLError -> m a
handleNoInputSDLError handleNoInput errorType = do
    let message = getSDLErrorMessage errorType
    errorString <- liftIO (SDL.getError >>= peekCString)
    liftIO $ handleNoInput (message ++ " SDL_Error: " ++ errorString)


logSDLError :: (MonadIO m) => SDLError -> m ()
logSDLError = handleNoInputSDLError print


throwSDLError :: SDLError -> SDLRisky a
throwSDLError = ExceptT . return . Left


getSDLErrorMessage :: SDLError -> String
getSDLErrorMessage (SDLInitError name)  = name ++ " could not initialize!"
getSDLErrorMessage (SetHintError hint)  = "Hint '" ++ hint ++ "' could not be applied!"
getSDLErrorMessage WindowError          = "Window could not be created!"
getSDLErrorMessage RendererError        = "Renderer could not be created!"
getSDLErrorMessage (SurfaceError path)  = "Unable to load image '" ++ path ++ "'!"
getSDLErrorMessage TextureError         = "Unable to create texture!"


