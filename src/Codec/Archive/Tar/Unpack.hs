-- TODO currently a problem with Tar is that it doesnt set the execuatable bit
-- see https://github.com/haskell/tar/issues/25

module Codec.Archive.Tar.Unpack
    ( unpack
    ) where

import           Control.Exception (Exception, throwIO)
import           Control.Exception as Exception (catch)
import           Control.Monad (unless)
import           Data.Bits (testBit)
import qualified Data.ByteString.Lazy as BS
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           System.Directory
                  (copyFile, createDirectoryIfMissing, emptyPermissions, setModificationTime,
                  setOwnerExecutable, setOwnerReadable, setOwnerSearchable, setOwnerWritable,
                  setPermissions)
import           System.FilePath ((</>))
import qualified System.FilePath as FilePath.Native (takeDirectory)
import           System.IO.Error (isPermissionError)

import           Codec.Archive.Tar hiding (unpack)
import           Codec.Archive.Tar.Check
import           Codec.Archive.Tar.Entry

-- | Create local files and directories based on the entries of a tar archive.
--
-- This is a portable implementation of unpacking suitable for portable
-- archives. It handles 'NormalFile' and 'Directory' entries and has simulated
-- support for 'SymbolicLink' and 'HardLink' entries. Links are implemented by
-- copying the target file. This therefore works on Windows as well as Unix.
-- All other entry types are ignored, that is they are not unpacked and no
-- exception is raised.
--
-- If the 'Entries' ends in an error then it is raised an an exception. Any
-- files or directories that have been unpacked before the error was
-- encountered will not be deleted. For this reason you may want to unpack
-- into an empty directory so that you can easily clean up if unpacking fails
-- part-way.
--
-- On its own, this function only checks for security (using 'checkSecurity').
-- You can do other checks by applying checking functions to the 'Entries' that
-- you pass to this function. For example:
--
-- > unpack dir (checkTarbomb expectedDir entries)
--
-- If you care about the priority of the reported errors then you may want to
-- use 'checkSecurity' before 'checkTarbomb' or other checks.
--
unpack :: Exception e => FilePath -> Entries e -> IO ()
unpack baseDir entries = unpackEntries [] (checkSecurity entries)
                     >>= emulateLinks

  where
    -- We're relying here on 'checkSecurity' to make sure we're not scribbling
    -- files all over the place.

    unpackEntries _     (Fail err)      = either throwIO throwIO err
    unpackEntries links Done            = return links
    unpackEntries links (Next entry es) = case entryContent entry of
      NormalFile file _ -> extractFile entry path file mtime
                        >> unpackEntries links es
      Directory         -> extractDir path mtime
                        >> unpackEntries links es
      HardLink     link -> (unpackEntries $! saveLink path link links) es
      SymbolicLink link -> (unpackEntries $! saveLink path link links) es
      _                 -> unpackEntries links es --ignore other file types
      where
        path  = entryPath entry
        mtime = entryTime entry

    extractFile entry path content mtime = do
      -- Note that tar archives do not make sure each directory is created
      -- before files they contain, indeed we may have to create several
      -- levels of directory.
      createDirectoryIfMissing True absDir
      BS.writeFile absPath content
      setOwnerPermissions absPath $ entryPermissions entry
      setModTime absPath mtime
      where
        absDir  = baseDir </> FilePath.Native.takeDirectory path
        absPath = baseDir </> path

    extractDir path mtime = do
      createDirectoryIfMissing True absPath
      setModTime absPath mtime
      where
        absPath = baseDir </> path

    saveLink path link links = seq (length path)
                             $ seq (length link')
                             $ (path, link'):links
      where link' = fromLinkTarget link

    emulateLinks = mapM_ $ \(relPath, relLinkTarget) ->
      let absPath   = baseDir </> relPath
          absTarget = FilePath.Native.takeDirectory absPath </> relLinkTarget
       in copyFile absTarget absPath

setModTime :: FilePath -> EpochTime -> IO ()
setModTime path t =
    setModificationTime path (posixSecondsToUTCTime (fromIntegral t))
      `Exception.catch` \e ->
        unless (isPermissionError e) $ throwIO e

setOwnerPermissions :: FilePath -> Permissions -> IO ()
setOwnerPermissions path permissions =
  setPermissions path ownerPermissions
  where
    ownerPermissions =
      setOwnerReadable   (testBit permissions 8) $
      setOwnerWritable   (testBit permissions 7) $
      setOwnerExecutable (testBit permissions 6) $
      setOwnerSearchable (testBit permissions 6)
      emptyPermissions
