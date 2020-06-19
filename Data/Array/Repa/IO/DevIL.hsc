module Data.Array.Repa.IO.DevIL (
    -- * The Image array type 
      Image (..)

    -- * The IL monad
    , IL, runIL

    -- * Image IO
    , readImage, writeImage
    ) where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative (Applicative, (<$>))
#endif

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (..))

import Data.Int
import Data.Word

import Foreign.C.String (CString, withCString)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Concurrent (newForeignPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Foreign.Marshal.Utils (with)

import Data.Array.Repa (Array (..), Z (..), (:.) (..), DIM2, DIM3, extent)
import Data.Array.Repa.Repr.ForeignPtr (F, fromForeignPtr, toForeignPtr)

#include "IL/il.h"

type ILuint    = #type ILuint
type ILsizei   = #type ILsizei
type ILboolean = #type ILboolean
type ILenum    = #type ILenum
type ILint     = #type ILint
type ILubyte   = #type ILubyte

-- DevIL uses unsigned integers as names for each image in processing.
newtype ImageName = ImageName ILuint 
    deriving (Show)

-- ----------------------------------------------------------------------

-- | RGBA, RGB, BGRA and BGR images are 3D repa arrays where indices are
-- /Z :. row :. column :. color channel/. Grey images are 2D repa arrays.
-- 
-- The origin (/Z :. 0 :. 0/) is on the lower left point of the image.
data Image = RGBA (Array F DIM3 Word8)
           | RGB (Array F DIM3 Word8)
           | BGRA (Array F DIM3 Word8)
           | BGR (Array F DIM3 Word8)
           | Grey (Array F DIM2 Word8)

-- | The IL monad. Provides statically-guaranteed access to an initialized IL
-- context.
newtype IL a = IL (IO a)
    deriving (Monad, MonadIO, Functor, Applicative)

-- | Running code in the /IL/ monad. This is a simple wrapper over /IO/
-- that guarantees the DevIL library has been initialized before you run
-- functions on it.
runIL :: IL a -> IO a
runIL (IL a) = ilInit >> a
{-# INLINE runIL #-}

-- | Reads an image into a repa array. It uses directly the C array using the
-- repa\'s foreign arrays wrapper.
-- 
-- Example:
-- 
-- > main = do
-- >    x <- runIL $ readImage "/tmp/x.png"
-- >    .. operations on x ..
-- 
-- /Note:/ The image input type is determined by the filename extension.
readImage :: FilePath -> IL Image
readImage f = liftIO $ do
    name <- ilGenImageName
    ilBindImage name

    success <- ilLoadImage f
    when (not success) $
       error "Unable to load the image."

    toRepa name

-- | Writes an 'Image' to a file. The image array must be represented as foreign
-- buffers. You can use 'copyS' or 'copyP' to convert the array.
-- 
-- /Note:/ The image output type is determined by the filename extension.
writeImage :: FilePath -> Image -> IL ()
writeImage f i = liftIO $ do
    name <- ilGenImageName
    ilBindImage name

    successCopy <- fromRepa i
    when (not successCopy) $
        error "Unable to copy the image to the DevIL buffer."

    successSave <- ilSaveImage f
    when (not successSave) $
        error "Unable to the save the image to the file."

    ilDeleteImage name

-- ----------------------------------------------------------------------

foreign import ccall unsafe "ilInit" ilInitC :: IO ()
foreign import ccall unsafe "ilOriginFunc" ilOriginFuncC :: ILenum -> IO ILboolean
foreign import ccall unsafe "ilEnable" ilEnableC :: ILenum -> IO ILboolean

-- | Initialize the library.
ilInit :: IO ()
ilInit = do
    ilInitC
    -- By default, origin is undefined and depends on the image type
    _ <- ilOriginFuncC (#const IL_ORIGIN_LOWER_LEFT)
    _ <- ilEnableC (#const IL_ORIGIN_SET)
    return ()
{-# INLINE ilInit #-}

foreign import ccall unsafe "ilGenImages" ilGenImagesC
  :: ILsizei -> Ptr ILuint -> IO ()

-- | Allocates a new image name.
ilGenImageName :: IO ImageName
ilGenImageName = do
    alloca $ \pName -> do
        ilGenImagesC 1 pName
        name <- peek pName
        return $! ImageName name
{-# INLINE ilGenImageName #-}

foreign import ccall unsafe "ilBindImage" ilBindImageC :: ILuint -> IO ()

-- | Sets the image name as the current image for processing.
ilBindImage :: ImageName -> IO ()
ilBindImage (ImageName name) = ilBindImageC name
{-# INLINE ilBindImage #-}

foreign import ccall unsafe "ilLoadImage" ilLoadImageC :: CString -> IO ILboolean

-- | Loads the image as the current DevIL image name.
ilLoadImage :: FilePath -> IO Bool
ilLoadImage f = (0 /=) <$> withCString f ilLoadImageC
{-# INLINE ilLoadImage #-}

foreign import ccall unsafe "ilGetInteger" ilGetIntegerC :: ILenum -> IO ILint

il_RGB, il_RGBA, il_BGR, il_BGRA, il_LUMINANCE :: ILenum
il_RGB = (#const IL_RGB)
il_RGBA = (#const IL_RGBA)
il_BGR = (#const IL_BGR)
il_BGRA = (#const IL_BGRA)
il_LUMINANCE = (#const IL_LUMINANCE)

il_IMAGE_HEIGHT, il_IMAGE_WIDTH :: ILenum
il_IMAGE_FORMAT, il_IMAGE_TYPE :: ILenum
il_UNSIGNED_BYTE :: ILenum
il_IMAGE_HEIGHT = (#const IL_IMAGE_HEIGHT)
il_IMAGE_WIDTH = (#const IL_IMAGE_WIDTH)
il_IMAGE_FORMAT = (#const IL_IMAGE_FORMAT)
il_IMAGE_TYPE = (#const IL_IMAGE_TYPE)
il_UNSIGNED_BYTE = (#const IL_UNSIGNED_BYTE)

foreign import ccall unsafe "ilConvertImage" ilConvertImageC
    :: ILenum -> ILenum -> IO ILboolean
foreign import ccall unsafe "ilGetData" ilGetDataC :: IO (Ptr ILubyte)

-- | Puts the current image inside a repa array.
toRepa :: ImageName -> IO Image
toRepa name = do
    width' <- ilGetIntegerC il_IMAGE_WIDTH
    height' <- ilGetIntegerC il_IMAGE_HEIGHT
    let (width, height) = (fromIntegral width', fromIntegral height')
    format <- ilGetIntegerC il_IMAGE_FORMAT
    pixelType <- fromIntegral <$> ilGetIntegerC il_IMAGE_TYPE

    case fromIntegral format :: ILenum of
        (#const IL_RGB) -> do
            convert il_RGB pixelType
            RGB <$> pixelsToArray (Z :. height :. width :. 3)
        (#const IL_RGBA) -> do
            convert il_RGBA pixelType
            RGBA <$> pixelsToArray (Z :. height :. width :. 4)
        (#const IL_BGR) -> do
            convert il_BGR pixelType
            BGR <$> pixelsToArray (Z :. height :. width :. 3)
        (#const IL_BGRA) -> do
            convert il_BGRA pixelType
            BGRA <$> pixelsToArray (Z :. height :. width :. 4)
        (#const IL_LUMINANCE) -> do
            convert il_LUMINANCE pixelType
            Grey <$> pixelsToArray (Z :. height :. width)
        _ -> do
            ilConvertImage il_RGBA il_UNSIGNED_BYTE
            RGBA <$> pixelsToArray (Z :. height :. width :. 4)
  where
    -- Converts the image to the given format if the pixel type isn't Word8.
    convert format pixelType
        | pixelType == il_UNSIGNED_BYTE = return ()
        | otherwise = ilConvertImage format il_UNSIGNED_BYTE

    -- Converts the C vector of unsigned bytes to a garbage collected repa 
    -- array.
    pixelsToArray dstExtent = do
        pixels <- ilGetDataC
        managedPixels <- newForeignPtr pixels (ilDeleteImage name)
        return $! fromForeignPtr dstExtent managedPixels

    ilConvertImage format pixelType = do
        success <- (0 /=) <$> ilConvertImageC format pixelType
        when (not success) $
                error "Unable to convert the image to a supported format."

foreign import ccall unsafe "ilTexImage" ilTexImageC
    :: ILuint -> ILuint -> ILuint   -- w h depth
    -> ILubyte -> ILenum -> ILenum  -- numberOfChannels format type
    -> Ptr ()                       -- data (copy from this pointer)
    -> IO ILboolean

-- | Copies the repa array to the current image buffer.
fromRepa :: Image -> IO Bool
fromRepa (RGB i)  =
    let Z :. h :. w :. _ = extent i
    in (0 /=) <$> (withForeignPtr (toForeignPtr i) $ \p ->
            ilTexImageC (fromIntegral w) (fromIntegral h) 1 3
                        (fromIntegral il_RGB) il_UNSIGNED_BYTE (castPtr p))
fromRepa (RGBA i) =
    let Z :. h :. w :. _ = extent i
    in (0 /=) <$> (withForeignPtr (toForeignPtr i) $ \p ->
            ilTexImageC (fromIntegral w) (fromIntegral h) 1 4
                        (fromIntegral il_RGBA) il_UNSIGNED_BYTE (castPtr p))
fromRepa (BGR i)  =
    let Z :. h :. w :. _ = extent i
    in (0 /=) <$> (withForeignPtr (toForeignPtr i) $ \p ->
            ilTexImageC (fromIntegral w) (fromIntegral h) 1 3
                        (fromIntegral il_BGR) il_UNSIGNED_BYTE (castPtr p))
fromRepa (BGRA i) =
    let Z :. h :. w :. _ = extent i
    in (0 /=) <$> (withForeignPtr (toForeignPtr i) $ \p ->
            ilTexImageC (fromIntegral w) (fromIntegral h) 1 4
                        (fromIntegral il_BGRA) il_UNSIGNED_BYTE (castPtr p))
fromRepa (Grey i) =
    let Z :. h :. w = extent i
    in (0 /=) <$> (withForeignPtr (toForeignPtr i) $ \p ->
            ilTexImageC (fromIntegral w) (fromIntegral h) 1 1
                        (fromIntegral il_LUMINANCE) il_UNSIGNED_BYTE 
                        (castPtr p))

foreign import ccall unsafe "ilSaveImage" ilSaveImageC :: CString -> IO ILboolean

-- | Saves the current image.
ilSaveImage :: FilePath -> IO Bool
ilSaveImage file = do
    (0 /=) <$> withCString file ilSaveImageC
{-# INLINE ilSaveImage #-}

foreign import ccall unsafe "ilDeleteImages" ilDeleteImagesC
    :: ILsizei -> Ptr ILuint -> IO ()

-- | Releases an image with its name.
ilDeleteImage :: ImageName -> IO ()
ilDeleteImage (ImageName name) =
    with name $ \pName ->
        ilDeleteImagesC 1 pName
{-# INLINE ilDeleteImage #-}
