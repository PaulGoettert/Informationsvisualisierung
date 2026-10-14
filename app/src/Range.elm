module Range exposing (Model, Msg, bounds, clearCache, datesBetween, init, load, reset, update)

import Api
import DailyCache
import Dict exposing (Dict)
import Http
import Set
import Weather exposing (Measurement)
import Year


type alias Job =
    { stationId : Int, date : String }


type alias Model =
    { start : String
    , end : String
    , dates : List String
    , stations : List Int
    , raw : Bool
    , started : Bool
    , generation : Int
    , results : Dict ( Int, String ) (Result String (List Measurement))
    , active : Set.Set ( Int, String )
    , queue : List Job
    , cache : DailyCache.Model
    }


type Msg
    = Got Int Job (Result Http.Error (List Measurement))


init : Model
init =
    { start = "2024-07-15", end = "2024-07-15", dates = [], stations = [], raw = True, started = False, generation = 0, results = Dict.empty, active = Set.empty, queue = [], cache = DailyCache.empty }


reset : Model -> Model
reset model =
    { init | generation = model.generation + 1, cache = model.cache }


clearCache : Model -> Model
clearCache model =
    { model | cache = DailyCache.empty }


bounds : Model -> Maybe ( String, String )
bounds model =
    if model.started then
        Just ( model.start, model.end )

    else
        Nothing


datesBetween : String -> String -> Result String (List String)
datesBetween start end =
    case ( Weather.dayBounds start, Weather.dayBounds end ) of
        ( Ok _, Ok _ ) ->
            if start > end then
                Err "Der Zeitraum beginnt nach seinem Ende."

            else
                Ok (List.filter (\date -> date >= start && date <= end) Year.dates)

        _ ->
            Err "Bitte wähle gültige Zeitraumgrenzen im Jahr 2024."


load : String -> String -> String -> String -> List Int -> Model -> Result String ( Model, Cmd Msg )
load base token start end stations previous =
    datesBetween start end
        |> Result.andThen
            (\dates ->
                if List.isEmpty stations then
                    Err "Wähle mindestens eine Station für den Zeitraum."

                else
                    let
                        raw =
                            List.length dates <= 7

                        model =
                            { init
                                | start = start
                                , end = end
                                , stations = stations
                                , dates = dates
                                , started = True
                                , raw = raw
                                , generation = previous.generation + 1
                                , cache = previous.cache
                                , results =
                                    if raw then
                                        Dict.filter (\( station, date ) _ -> List.member station stations && List.member date dates) previous.cache.entries |> Dict.map (\_ rows -> Ok rows)

                                    else
                                        Dict.empty
                                , queue =
                                    if raw then
                                        List.concatMap
                                            (\date ->
                                                List.filterMap
                                                    (\station ->
                                                        if DailyCache.get station date previous.cache == Nothing then
                                                            Just (Job station date)

                                                        else
                                                            Nothing
                                                    )
                                                    stations
                                            )
                                            dates

                                    else
                                        []
                            }
                    in
                    Ok (pump base token model)
            )


pump : String -> String -> Model -> ( Model, Cmd Msg )
pump base token model =
    let
        jobs =
            List.take (2 - Set.size model.active) model.queue

        request job =
            case Weather.dayBounds job.date of
                Ok ( start, end ) ->
                    Api.measurements base token job.stationId start end (Got model.generation job)

                Err _ ->
                    Cmd.none
    in
    ( { model | queue = List.drop (List.length jobs) model.queue, active = List.foldl (\job -> Set.insert ( job.stationId, job.date )) model.active jobs }
    , Cmd.batch (List.map request jobs)
    )


update : String -> String -> Msg -> Model -> ( Model, Cmd Msg )
update base token (Got generation job result) model =
    if generation /= model.generation || not (Set.member ( job.stationId, job.date ) model.active) then
        ( model, Cmd.none )

    else
        let
            rows =
                case result of
                    Ok values ->
                        Weather.validate job.stationId job.date values

                    Err (Http.BadStatus status) ->
                        Err ("HTTP " ++ String.fromInt status)

                    Err Http.Timeout ->
                        Err "Zeitüberschreitung"

                    Err (Http.BadBody _) ->
                        Err "Ungültiges Datenformat"

                    Err _ ->
                        Err "Datenserver nicht erreichbar"
        in
        pump base
            token
            { model
                | results = Dict.insert ( job.stationId, job.date ) rows model.results
                , active = Set.remove ( job.stationId, job.date ) model.active
                , cache =
                    case rows of
                        Ok values ->
                            DailyCache.remember job.stationId job.date values model.cache

                        Err _ ->
                            model.cache
            }
