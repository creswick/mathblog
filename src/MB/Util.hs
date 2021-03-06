module MB.Util
    ( copyTree
    , toUtcTime
    , toLocalTime
    , pandocTitle
    , pandocTitleRaw
    , rssModificationTime
    , loadPostIndex
    , getModificationTime
    , allPostFilenames
    , dirFilenames
    , anyChanges
    , summarizeChanges
    , serializePostIndex
    )
where
import Control.Applicative
    ( (<$>)
    , (<*>)
    , pure
    )
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , createDirectory
    , getDirectoryContents
    , copyFile
    )
import System.FilePath
    ( (</>)
    , takeFileName
    )
import Control.Monad
    ( when
    , forM_
    , forM
    , filterM
    )
import System.Exit
    ( exitFailure
    )
import System.Posix.Files
    ( getFileStatus
    , modificationTime
    )
import System.Posix.Types
    ( EpochTime
    )
import Data.List
    ( isSuffixOf
    , isPrefixOf
    )
import Data.Time.Clock
    ( UTCTime(utctDay)
    , getCurrentTime
    )
import Data.Time.Calendar
    ( addDays
    )
import Data.Time.Format
    ( parseTime
    , formatTime
    )
import Data.Time.LocalTime
    ( LocalTime
    , getCurrentTimeZone
    , utcToLocalTime
    )
import System.Locale
    ( defaultTimeLocale
    , rfc822DateFormat
    )
import System.IO
    ( IOMode(ReadMode)
    , openFile
    , hClose
    , hGetContents
    )
import Data.List
    ( sortBy
    )
import Data.Maybe
    ( fromJust
    , catMaybes
    )
import qualified Text.Pandoc as Pandoc
import qualified MB.Files as Files
import MB.Types

copyTree :: FilePath -> FilePath -> IO ()
copyTree srcPath dstPath = do
  dstFExists <- doesFileExist dstPath
  dstDExists <- doesDirectoryExist dstPath

  when (dstFExists || dstDExists) $ do
    putStrLn $ "Cannot copy " ++ (show srcPath) ++ " to existing destination path " ++
                 (show dstPath) ++ "; remove to continue."
    exitFailure

  createDirectory dstPath
  copyTree' srcPath dstPath

  where
    copyTree' src dst = do
      -- For each file in src, copy it to dest.
      entries <- filter (not . flip elem [".", ".."]) <$> getDirectoryContents src

      dirs <- filterM doesDirectoryExist $ map (src </>) entries
      files <- filterM doesFileExist $ map (src </>) entries

      -- For each directory in src, create it in dest, then descend
      -- into that directory in both src and dest.
      forM_ files $ \f -> copyFile f $ dst </> takeFileName f
      forM_ dirs $ \dir ->
          do
            let dstDir = dst </> dirName
                dirName = takeFileName dir

            createDirectory dstDir
            copyTree' (src </> dirName) dstDir

toUtcTime :: EpochTime -> UTCTime
toUtcTime t = fromJust $ parseTime defaultTimeLocale "%s" $ show t

toLocalTime :: UTCTime -> IO LocalTime
toLocalTime u = do
  tz <- getCurrentTimeZone
  return $ utcToLocalTime tz u

pandocTitle :: Pandoc.Pandoc -> String
pandocTitle (Pandoc.Pandoc m _) = concat $ map getStr $ Pandoc.docTitle m
    where
      getStr (Pandoc.Str s) = s
      getStr (Pandoc.Math _ s) = "\\(" ++ s ++ "\\)"
      getStr Pandoc.Space = " "
      getStr i = error $ "Unexpected inline in document title, got " ++ (show i)

pandocTitleRaw :: Pandoc.Pandoc -> String
pandocTitleRaw (Pandoc.Pandoc m _) = concat $ map getStr $ Pandoc.docTitle m
    where
      getStr (Pandoc.Str s) = s
      getStr (Pandoc.Math _ s) = s
      getStr Pandoc.Space = " "
      getStr i = error $ "Unexpected inline in document title, got " ++ (show i)

rssModificationTime :: Post -> String
rssModificationTime =
    formatTime defaultTimeLocale rfc822DateFormat . postModificationTime

loadPost :: FilePath -> IO Post
loadPost fullPath = do
  fileContent <- readFile fullPath
  t <- getModificationTime fullPath
  let doc = Pandoc.readMarkdown Pandoc.defaultParserState fileContent

  return $ Post { postTitle = pandocTitle doc
                , postTitleRaw = pandocTitleRaw doc
                , postPath = fullPath
                , postFilename = takeFileName fullPath
                , postModificationTime = t
                , postAst = doc
                }

dirFilenames :: FilePath -> IO [FilePath]
dirFilenames dir = do
  allFiles <- getDirectoryContents dir
  return [ dir </> f | f <- allFiles
         , not $ "." `isPrefixOf` f
         ]

allPostFilenames :: FilePath -> IO [FilePath]
allPostFilenames postSrcDir = do
  allFiles <- dirFilenames postSrcDir
  return [ f | f <- allFiles
         , ".txt" `isSuffixOf` f
         ]

getModificationTime :: FilePath -> IO UTCTime
getModificationTime fullPath = do
  info <- getFileStatus fullPath
  return $ toUtcTime $ modificationTime info

loadPostIndex :: FilePath -> IO [Post]
loadPostIndex postSrcDir = do
  let indexFilename = postSrcDir </> "posts-index"
  e <- doesFileExist indexFilename

  indexNames <- case e of
                  False -> return []
                  True -> do
                         h <- openFile indexFilename ReadMode
                         s <- hGetContents h
                         s `seq` return ()
                         let idx = unserializePostIndex s
                         hClose h
                         return idx

  -- Now that we have a postIndex to deal with, load posts from disk
  -- and insert them into the post index in the proper order

  postFiles <- allPostFilenames postSrcDir
  posts <- mapM loadPost postFiles

  -- There are two types of posts to put into the index: the ones that
  -- are not already in the index, and the ones that are (and in a
  -- specific order).

  let pairs = [ (postFilename p, p) | p <- posts ]
      newPosts = [ p | p <- posts, not $ postFilename p `elem` indexNames ]
      preexistingPosts = catMaybes [ lookup n pairs | n <- indexNames ]
      ps = sortPosts newPosts ++ preexistingPosts

  return ps

serializePostIndex :: [Post] -> String
serializePostIndex ps = unlines $ map postFilename ps

unserializePostIndex :: String -> [String]
unserializePostIndex = lines

sortPosts :: [Post] -> [Post]
sortPosts = sortBy (\a b -> postModificationTime b `compare`
                            postModificationTime a)

anyChanges :: ChangeSummary -> Bool
anyChanges s = or $ predicates <*> pure s
    where
      predicates = [ configChanged
                   , not . null . postsChanged
                   , templatesChanged
                   , postIndexChanged
                   ]

summarizeChanges :: Config -> IO ChangeSummary
summarizeChanges config = do
  -- Determine whether the configuration file changed.  Check to see
  -- if it's newer than the index.html file, or if no index.html
  -- exists then that's equivalent to "the config changed"
  configMtime <- getModificationTime $ configPath config
  indexExists <- doesFileExist $ Files.indexHtml config
  baseTime <- case indexExists of
                False -> do
                  t <- getCurrentTime
                  return $ t { utctDay = addDays (- 1) $ utctDay t }
                True -> getModificationTime $ Files.indexHtml config

  postIndexExists <- doesFileExist $ Files.postIndex config
  postIndexChanged' <- case postIndexExists of
                         False -> return True
                         True -> do
                            t <- getModificationTime $ Files.postIndex config
                            return $ t > baseTime

  let configChanged' = configMtime > baseTime
      modifiedPosts = filter (\p -> postModificationTime p > baseTime) $ blogPosts config

  -- Determine whether any templates changed
  templateFiles <- dirFilenames (templateDir config)
  templateChanges <- forM templateFiles $ \f -> do
                            mtime <- getModificationTime f
                            return $ mtime > baseTime

  return $ ChangeSummary { configChanged = configChanged'
                         , postsChanged = map postFilename modifiedPosts
                         , templatesChanged = or templateChanges
                         , postIndexChanged = postIndexChanged'
                         }
