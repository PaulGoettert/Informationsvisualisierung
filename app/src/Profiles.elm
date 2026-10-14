module Profiles exposing (Model, Msg, Stat, init, load, reset, update)

import Dict exposing (Dict)
import Http
import Json.Decode as Decode
import Set exposing (Set)
import Weather
import Year


type alias Stat =
    { count : Int, value : Maybe Float, gap : Int, qualityWarning : Bool }


type alias Interval =
    { stationId : Int, timestamp : String, value : Maybe Float, quality : Int }


type alias Job =
    { stationId : Int, month : Int, kind : Int }


type alias Buffer =
    { rows : List Interval, pages : Int }


type alias Model =
    { stats : Dict ( Int, Int, String ) Stat
    , done : Set ( Int, Int, Int )
    , errors : Dict ( Int, Int, Int ) String
    , active : Dict ( Int, Int, Int ) Buffer
    , queue : List Job
    , generation : Int
    , started : Bool
    }


type Msg
    = Page Int Job Int (Result Http.Error (List Interval))


init : Model
init =
    { stats = Dict.empty, done = Set.empty, errors = Dict.empty, active = Dict.empty, queue = [], generation = 0, started = False }


reset : Model -> Model
reset model =
    { init | generation = model.generation + 1 }


key : Job -> ( Int, Int, Int )
key job =
    ( job.stationId, job.month, job.kind )


load : String -> String -> Model -> ( Model, Cmd Msg )
load base token model =
    if not (Dict.isEmpty model.active) then
        ( model, Cmd.none )

    else
        let
            jobs =
                List.concatMap (\month -> List.concatMap (\station -> List.map (Job station.id month) [ 0, 1 ]) Weather.stations) (List.range 1 12)
                    |> List.filter (\job -> not (Set.member (key job) model.done))
        in
        pump base token { model | queue = jobs, errors = Dict.empty, generation = model.generation + 1, started = True }


pump : String -> String -> Model -> ( Model, Cmd Msg )
pump base token model =
    let
        jobs =
            List.take (2 - Dict.size model.active) model.queue
    in
    ( { model | queue = List.drop (List.length jobs) model.queue, active = List.foldl (\job -> Dict.insert (key job) { rows = [], pages = 0 }) model.active jobs }
    , Cmd.batch (List.map (\job -> request base token model.generation job 0) jobs)
    )


request : String -> String -> Int -> Job -> Int -> Cmd Msg
request base token generation job offset =
    let
        ( start, end ) =
            Year.monthBounds job.month

        ( view, field ) =
            if job.kind == 0 then
                ( "v_wind", "windgeschw_ms" )

            else
                ( "v_precipitation", "niederschlag_mm" )

        normalize value =
            if value == Just -999 || value == Just -99.9 then
                Nothing

            else
                value

        decoder =
            Decode.list
                (Decode.map4 Interval
                    (Decode.field "station_id" Decode.int)
                    (Decode.field "timestamp" Decode.string)
                    (Decode.field field (Decode.map normalize (Decode.nullable Decode.float)))
                    (Decode.field "quality_class_id" Decode.int)
                )
    in
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token), Http.header "Accept-Profile" "dwd" ]
        , url =
            base
                ++ "/"
                ++ view
                ++ "?station_id=eq."
                ++ String.fromInt job.stationId
                ++ "&timestamp=gt."
                ++ start
                ++ "&timestamp=lte."
                ++ end
                ++ "&select=station_id,timestamp,"
                ++ field
                ++ ",quality_class_id&order=timestamp.asc&limit=5000&offset="
                ++ String.fromInt offset
        , body = Http.emptyBody
        , expect = Http.expectJson (Page generation job offset) decoder
        , timeout = Just 30000
        , tracker = Nothing
        }


update : String -> String -> Msg -> Model -> ( Model, Cmd Msg )
update base token (Page generation job offset result) model =
    case Dict.get (key job) model.active of
        Nothing ->
            ( model, Cmd.none )

        Just buffer ->
            if generation /= model.generation || offset /= List.length buffer.rows then
                ( model, Cmd.none )

            else
                case result of
                    Err error ->
                        finish base token job (Err (errorText error)) model

                    Ok rows ->
                        let
                            combined =
                                buffer.rows ++ rows

                            expected =
                                List.length (Year.datesInMonth job.month) * 144
                        in
                        if List.length combined > expected then
                            finish base token job (Err "Mehr Intervallwerte als im Monatsraster erlaubt.") model

                        else if List.isEmpty rows || List.length combined == expected then
                            finish base token job (aggregate job combined) model

                        else if buffer.pages >= 11 then
                            finish base token job (Err "Abruf nach zwölf Seiten abgebrochen; bitte erneut versuchen.") model

                        else
                            ( { model | active = Dict.insert (key job) { rows = combined, pages = buffer.pages + 1 } model.active }
                            , request base token generation job (List.length combined)
                            )


errorText : Http.Error -> String
errorText error =
    case error of
        Http.BadStatus status ->
            "HTTP " ++ String.fromInt status ++ ": Zugriff oder Serverantwort prüfen."

        Http.Timeout ->
            "Zeitüberschreitung beim Intervallabruf."

        Http.BadBody _ ->
            "Unerwartetes Datenformat der Intervallwerte."

        _ ->
            "Intervallwerte konnten nicht abgerufen werden."


finish : String -> String -> Job -> Result String (Dict ( Int, Int, String ) Stat) -> Model -> ( Model, Cmd Msg )
finish base token job result model =
    let
        next =
            { model | active = Dict.remove (key job) model.active }
    in
    case result of
        Err error ->
            pump base token { next | errors = Dict.insert (key job) error next.errors }

        Ok stats ->
            pump base token { next | stats = Dict.union stats next.stats, done = Set.insert (key job) next.done }


aggregate : Job -> List Interval -> Result String (Dict ( Int, Int, String ) Stat)
aggregate job rows =
    let
        calendar =
            Year.datesInMonth job.month

        -- Nominale Intervallenden: 00:10..23:50, dann 00:00 des Folgetags.
        timestamps date =
            let
                end =
                    Weather.dayBounds date |> Result.map Tuple.second |> Result.withDefault ""

                stamp slot =
                    if slot == 144 then
                        end

                    else
                        date ++ "T" ++ String.padLeft 2 '0' (String.fromInt (slot // 6)) ++ ":" ++ String.padLeft 2 '0' (String.fromInt (modBy 6 slot * 10)) ++ ":00"
            in
            List.map (\slot -> ( stamp slot, ( date, slot - 1 ) )) (List.range 1 144)

        allowed =
            List.concatMap timestamps calendar |> Dict.fromList

        grouped =
            List.foldl
                (\row previous ->
                    case Dict.get row.timestamp allowed of
                        Just ( date, slot ) ->
                            Dict.update date (\old -> Just (( slot, row ) :: Maybe.withDefault [] old)) previous

                        Nothing ->
                            previous
                )
                Dict.empty
                rows

        stat date =
            let
                dayRows =
                    Dict.get date grouped |> Maybe.withDefault [] |> List.sortBy Tuple.first

                valid =
                    List.filter (\( _, row ) -> row.value /= Nothing && row.quality /= 0) dayRows

                numbers =
                    List.filterMap (Tuple.second >> .value) valid

                warning =
                    List.any (Tuple.second >> .quality >> (/=) 3) dayRows

                occupied =
                    List.map Tuple.first valid |> Set.fromList

                gap slot ( current, longest ) =
                    if Set.member slot occupied then
                        ( 0, longest )

                    else
                        ( current + 1, max longest (current + 1) )

                maxGap =
                    List.foldl gap ( 0, 0 ) (List.range 0 143) |> Tuple.second

                value =
                    if List.length numbers == 144 && not warning then
                        Just
                            (if job.kind == 0 then
                                List.sum numbers / 144

                             else
                                List.sum numbers
                            )

                    else
                        Nothing
            in
            ( ( job.stationId, job.kind, date ), Stat (List.length numbers) value (maxGap * 10) warning )
    in
    if List.any (\row -> row.stationId /= job.stationId || not (Dict.member row.timestamp allowed) || (row.value |> Maybe.map (\value -> value < 0) |> Maybe.withDefault False)) rows then
        Err "Station, Intervallzeit oder Messwert liegt außerhalb des angefragten Monatsrasters."

    else if Set.size (Set.fromList (List.map .timestamp rows)) /= List.length rows then
        Err "Doppelte Intervallzeitstempel in der Monatsantwort."

    else
        Ok (List.map stat calendar |> Dict.fromList)
