module DailyCache exposing (Model, empty, get, remember)

import Dict exposing (Dict)
import Weather exposing (Measurement)


type alias Model =
    { entries : Dict ( Int, String ) (List Measurement)
    , order : List ( Int, String )
    }


empty : Model
empty =
    { entries = Dict.empty, order = [] }


get : Int -> String -> Model -> Maybe (List Measurement)
get station date model =
    Dict.get ( station, date ) model.entries


remember : Int -> String -> List Measurement -> Model -> Model
remember station date rows model =
    let
        key =
            ( station, date )

        order =
            List.take 28 (key :: List.filter ((/=) key) model.order)

        entries =
            Dict.insert key rows model.entries
    in
    { entries = Dict.filter (\entry _ -> List.member entry order) entries, order = order }
