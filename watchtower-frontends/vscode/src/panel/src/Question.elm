module Question exposing (Answer(..), TypeSignature, ask)

{-| -}

import Editor
import Http
import Json.Decode
import Url
import Url.Builder


watchtower : List String -> List Url.Builder.QueryParameter -> String
watchtower =
    Url.Builder.crossOrigin "http://localhost:51213"


ask : { missingTypesignatures : String -> Cmd (Result Http.Error Answer) }
ask =
    { missingTypesignatures =
        \path ->
            Http.get
                { url =
                    watchtower
                        [ "list-missing-signatures"
                        ]
                        [ Url.Builder.string "file" path
                        ]
                , expect =
                    Http.expectJson
                        (Result.map (MissingTypeSignatures path))
                        (Json.Decode.list
                            decodeMissingTypesignature
                        )
                }
    }


type Answer
    = MissingTypeSignatures String (List TypeSignature)


type alias TypeSignature =
    { name : String
    , region : Editor.Region
    , signature : String
    }


decodeMissingTypesignature =
    Json.Decode.map3 TypeSignature
        (Json.Decode.field "name" Json.Decode.string)
        (Json.Decode.field "region" Editor.decodeRegion)
        (Json.Decode.field "signature" Json.Decode.string)
