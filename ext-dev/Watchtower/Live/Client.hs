{-# LANGUAGE OverloadedStrings #-}

module Watchtower.Live.Client
    ( Client(..),ClientId, ProjectRoot, State(..), ProjectCache(..), ProjectStatus(..)
    , getAllStatuses, getRoot, getProjectRoot, getClientData
    , Outgoing(..), encodeOutgoing, outgoingToLog
    , Incoming(..), decodeIncoming, encodeWarning
    , broadcast, broadcastTo
    , matchingProject
    , isWatchingFileForWarnings, isWatchingFileForDocs
    , emptyWatch
    , watchProjects
    , watchTheseFilesOnly

    , watchedFiles
    ) where


{-| This could probably be renamed Live.State or something.  Client is a little weird but :shrug:


-}

import qualified Data.ByteString.Lazy
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString.Builder
import qualified Data.List as List
import qualified Data.Map as Map


import qualified Control.Concurrent.STM as STM
import Control.Monad as Monad (foldM, guard)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString.Builder
import qualified Data.Either as Either

import qualified Ext.Sentry
import qualified Ext.Dev.Project
import qualified Watchtower.Websocket
import qualified Watchtower.Editor
import qualified Reporting.Annotation as Ann
import qualified Reporting.Warning as Warning
import qualified Elm.Docs as Docs


import qualified Data.Name as Name

import qualified System.FilePath as FilePath
import qualified Json.Decode
import Json.Encode ((==>))
import qualified Json.Encode
import qualified Json.String
import qualified Reporting.Doc
import qualified Reporting.Render.Type
import qualified Reporting.Render.Type.Localizer
import qualified Ext.Common
import qualified Ext.Log

data State = State
  { clients :: STM.TVar [Client],
    projects ::
      STM.TVar
        [ProjectCache]
  }

data ProjectCache = ProjectCache
  { project :: Ext.Dev.Project.Project
  , sentry :: Ext.Sentry.Cache
  }

type ClientId = T.Text

type Client = Watchtower.Websocket.Client Watching

emptyWatch :: Watching
emptyWatch =
    Watching Set.empty Map.empty

data Watching = Watching
    { watchingProjects :: Set.Set ProjectRoot
    , watchingFiles :: Map.Map FilePath FileWatchType
    }

data FileWatchType
    = FileWatchType
        { watchForWarnings :: Bool -- missing type signatures/unused stuff
        , watchForDocs :: Bool
        }

type ProjectRoot = FilePath


watchedFiles :: Watching -> Map.Map FilePath FileWatchType
watchedFiles (Watching _ files) =
  files

getClientData :: ClientId -> State -> IO (Maybe Watching)
getClientData clientId (State mClients _) = do
  clients <- STM.atomically $ STM.readTVar mClients

  pure (List.foldl 
          (\found client -> 
              case found of
                  Nothing ->
                    if Watchtower.Websocket.matchId clientId client then 
                      Just (Watchtower.Websocket.clientData client)
                    else
                      Nothing

                  _ ->
                      found
          )
          Nothing
          clients
        )

  

watchProjects :: [ProjectRoot] -> Watching -> Watching
watchProjects newRoots (Watching watchingProjects watchingFiles) =
    Watching (Set.union watchingProjects (Set.fromList newRoots)) watchingFiles


watchTheseFilesOnly :: Map.Map FilePath FileWatchType -> Watching -> Watching
watchTheseFilesOnly newFileWatching (Watching watchingProjects watchingFiles) =
    Watching watchingProjects newFileWatching


isWatchingProject :: Ext.Dev.Project.Project -> Watching -> Bool
isWatchingProject proj (Watching watchingProjects watchingFiles) =
    Set.member (Ext.Dev.Project._root proj) watchingProjects


isWatchingFileForWarnings :: FilePath -> Watching -> Bool
isWatchingFileForWarnings file (Watching watchingProjects watchingFiles) =
    case Map.lookup file watchingFiles of
        Nothing -> False
        Just (FileWatchType _ watchForWarnings) ->
            watchForWarnings


isWatchingFileForDocs :: FilePath -> Watching -> Bool
isWatchingFileForDocs file (Watching watchingProjects watchingFiles) =
    case Map.lookup file watchingFiles of
        Nothing -> False
        Just (FileWatchType watchForDocs _) ->
            watchForDocs


getRoot :: FilePath -> State -> IO (Maybe FilePath)
getRoot path (State mClients mProjects) =
  do
    projects <- STM.readTVarIO mProjects
    pure (getRootHelp path projects Nothing)

getRootHelp path projects found =
  case projects of
    [] -> found
    (ProjectCache project _) : remain ->
      if Ext.Dev.Project.contains path project
        then case found of
          Nothing ->
            getRootHelp path remain (Just (Ext.Dev.Project._root project))
          Just root ->
            if List.length (Ext.Dev.Project._root project) > List.length root
              then getRootHelp path remain (Just (Ext.Dev.Project._root project))
              else getRootHelp path remain found
        else getRootHelp path remain found



getProjectRoot :: ProjectCache -> FilePath
getProjectRoot (ProjectCache proj _) =
    Ext.Dev.Project.getRoot proj

matchingProject :: ProjectCache -> ProjectCache -> Bool
matchingProject (ProjectCache one _) (ProjectCache two _) =
  Ext.Dev.Project.equal one two

getAllStatuses :: State -> IO [ProjectStatus]
getAllStatuses state@(State mClients mProjects) =
  do
    projects <- STM.readTVarIO mProjects

    Monad.foldM
      (\statuses proj ->
        do
          status <- getStatus proj
          pure (status : statuses)
      )
      []
      projects


getStatus :: ProjectCache -> IO ProjectStatus
getStatus (ProjectCache proj cache) =
    do
        compileResult <- Ext.Sentry.getCompileResult cache
        let successful = Either.isRight compileResult
        let json = (case compileResult of
                      Left j -> j
                      Right j -> j
                    )
        pure (ProjectStatus proj successful json)



{-
-}
data Incoming
  = Discover FilePath (Map.Map FilePath FileWatchType)
  | Changed FilePath
  | Watched (Map.Map FilePath FileWatchType)


data Outgoing
  = -- forwarding information
    ElmStatus [ ProjectStatus ]
  | Warnings FilePath Reporting.Render.Type.Localizer.Localizer [Warning.Warning]
  | Docs FilePath [Docs.Module]



outgoingToLog :: Outgoing -> String
outgoingToLog outgoing =
  case outgoing of
    ElmStatus projectStatusList ->
      "Status: " ++ Ext.Common.formatList (fmap projectStatusToString projectStatusList)

    Warnings _ _ warnings ->
      show (length warnings) <> " warnings"

    Docs _ _ ->
      "Docs"


projectStatusToString :: ProjectStatus -> String
projectStatusToString (ProjectStatus proj success json) =
    if success then
        "Success: ../" ++ FilePath.takeBaseName (Ext.Dev.Project.getRoot proj)
    else
        "Failing: ../" ++ FilePath.takeBaseName (Ext.Dev.Project.getRoot proj)




data ProjectStatus = ProjectStatus
  { _project :: Ext.Dev.Project.Project
  , _success :: Bool
  , _json :: Json.Encode.Value
  }
  deriving (Show)



encodeOutgoing :: Outgoing -> Data.ByteString.Builder.Builder
encodeOutgoing out =
  Json.Encode.encodeUgly $
    case out of
      ElmStatus statuses ->
        Json.Encode.object
          [ "msg" ==> Json.Encode.string (Json.String.fromChars "Status"),
            "details"
              ==> Json.Encode.list
                ( \(ProjectStatus project success status) ->
                    Json.Encode.object
                      [ "root"
                          ==> Json.Encode.string
                            ( Json.String.fromChars
                                (Ext.Dev.Project._root project)
                            ),
                        "status" ==> status
                      ]
                )
                statuses
          ]

      Warnings path localizer warnings ->
        Json.Encode.object
          [ "msg" ==> Json.Encode.string (Json.String.fromChars "Warnings"),
            "details"
              ==> Json.Encode.object
                    [ "filepath" ==> Json.Encode.string (Json.String.fromChars path)
                    , "warnings" ==>
                        Json.Encode.list
                          (encodeWarning localizer)
                          warnings
                    ]
          ]

      Docs path docs ->
        Json.Encode.object
          [ "msg" ==> Json.Encode.string (Json.String.fromChars "Docs"),
            "details"
              ==> Json.Encode.object
                    [ "filepath" ==> Json.Encode.string (Json.String.fromChars path)
                    , "docs" ==>
                        Docs.encode (Docs.toDict docs)
                    ]
          ]


{- Decoding -}


decodeIncoming :: Json.Decode.Decoder T.Text Incoming
decodeIncoming =
  Json.Decode.field "msg" Json.Decode.string
    >>= ( \msg ->
            case msg of
              "Changed" ->
                    Changed
                    <$> (Json.Decode.field "details"
                            (Json.Decode.field "path" (Json.String.toChars <$> Json.Decode.string))
                        )

              "Discover" ->
                    Json.Decode.field "details"
                      (Discover 
                          <$> Json.Decode.field "root" (Json.String.toChars <$> Json.Decode.string)
                          <*> Json.Decode.field "watching" decodeWatched
                      )           
                       

              "Watched" ->
                    Watched 
                       <$> Json.Decode.field "details" 
                            decodeWatched

              _ ->
                Json.Decode.failure "Unknown msg"
        )

decodeWatched :: Json.Decode.Decoder T.Text (Map.Map FilePath FileWatchType)
decodeWatched =
  fmap
    Map.fromList
    (Json.Decode.list
      ((\path warns docs ->
          ( path
          , FileWatchType warns docs
          )
        )
        <$> Json.Decode.field "path" (Json.String.toChars <$> Json.Decode.string)
        <*> Json.Decode.field "warnings" Json.Decode.bool
        <*> Json.Decode.field "docs" Json.Decode.bool
      )
    )


{- Encoding -}


encodeStatus (Ext.Dev.Project.Project root entrypoints, js) =
  Json.Encode.object
    [ "root" ==> Json.Encode.string (Json.String.fromChars root),
      "entrypoints" ==> Json.Encode.list (Json.Encode.string . Json.String.fromChars) entrypoints,
      "status" ==> js
    ]


encodeWarning localizer warning =
  case warning of
    Warning.UnusedImport region name ->
      Json.Encode.object
          [ "warning" ==> (Json.Encode.chars "UnusedImport")
          , "region" ==>
              (Watchtower.Editor.encodeRegion region)
          , "name" ==>
              (Json.Encode.chars (Name.toChars name))
          ]

    Warning.UnusedVariable region defOrPattern name ->
      Json.Encode.object
          [ "warning" ==> (Json.Encode.chars "UnusedVariable")
          , "region" ==>
              (Watchtower.Editor.encodeRegion region)
          , "context" ==>
              (case defOrPattern of
                  Warning.Def -> Json.Encode.chars "def"

                  Warning.Pattern -> Json.Encode.chars "pattern"

              )
          , "name" ==>
              (Json.Encode.chars (Name.toChars name))
          ]

    Warning.MissingTypeAnnotation region name type_ ->
      Json.Encode.object
          [ "warning" ==> (Json.Encode.chars "MissingAnnotation")
          , "region" ==>
              (Watchtower.Editor.encodeRegion region)
          , "name" ==>
              (Json.Encode.chars (Name.toChars name))
          , "signature" ==>
              (Json.Encode.chars
                (Reporting.Doc.toString
                  (Reporting.Render.Type.canToDoc localizer Reporting.Render.Type.None type_)
                )
              )
          ]





{- Broadcasting -}

builderToString =
  T.decodeUtf8 . Data.ByteString.Lazy.toStrict . Data.ByteString.Builder.toLazyByteString


broadcastAll :: STM.TVar [Client] -> Outgoing -> IO ()
broadcastAll allClients outgoing =
  Watchtower.Websocket.broadcastWith
    allClients
    (\c -> True)
    ( builderToString $
        encodeOutgoing outgoing
    )


broadcastTo :: STM.TVar [Client] -> ClientId -> Outgoing -> IO ()
broadcastTo allClients id outgoing =
  do
    Ext.Log.log Ext.Log.Live (outgoingToLog outgoing)
    Watchtower.Websocket.broadcastWith
      allClients
      ( Watchtower.Websocket.matchId id
      )
      ( builderToString $
          encodeOutgoing outgoing
      )


broadcastToMany :: STM.TVar [Client] -> (Client -> Bool) -> Outgoing -> IO ()
broadcastToMany allClients shouldBroadcast outgoing =
    do
      Ext.Log.log Ext.Log.Live (outgoingToLog outgoing)
      Watchtower.Websocket.broadcastWith
        allClients
        shouldBroadcast
        ( builderToString $
            encodeOutgoing outgoing
        )



broadcast :: STM.TVar [Client] -> Outgoing -> IO ()
broadcast mClients msg =
  case msg of
    ElmStatus projectStatusList ->
        do
            broadcastToMany
                mClients
                ( \client ->
                        let
                            clientData = Watchtower.Websocket.clientData client

                            affectedProjectsThatWereListeningTo =
                                List.filter
                                    (\(ProjectStatus proj _ _) ->
                                        isWatchingProject proj clientData
                                    )
                                    projectStatusList
                        in
                        -- This isn't entirely correct as it'll give all project statuses to this client
                        -- but :shrug: for now.
                        case affectedProjectsThatWereListeningTo of
                            [] -> False
                            _ ->
                                True
                )
                msg

    Warnings file localizer warnings ->
        do
            broadcastToMany
                mClients
                ( \client ->
                        -- This lookup was failing
                        -- possibly because the filepath format differs from the map?
                        -- let
                        --     clientData = Watchtower.Websocket.clientData client
                        -- in
                        -- isWatchingFileForWarnings file clientData
                        True
                )
                msg

    Docs file docs ->
        do
            broadcastToMany
                mClients
                ( \client ->
                        -- This lookup was failing
                        -- possibly because the filepath format differs from the map?
                        -- let
                        --     clientData = Watchtower.Websocket.clientData client
                        -- in
                        -- isWatchingFileForDocs file clientData
                        True
                )
                msg