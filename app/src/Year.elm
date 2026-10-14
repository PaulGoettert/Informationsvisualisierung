module Year exposing (Daily, aggregateMonth, dates, datesInMonth, indexOf, monthBounds, monthOf)

import Dict exposing (Dict)
import Set
import Weather exposing (Measurement)


type alias Daily =
    { date : String
    , rows : Int
    , temperatureCount : Int
    , humidityCount : Int
    , temperatureMean : Maybe Float
    , humidityMean : Maybe Float
    , maxTemperatureGap : Int
    , qualityWarning : Bool
    , temperatureSlots : Set.Set Int
    }


pad : Int -> String
pad =
    String.padLeft 2 '0' << String.fromInt


datesInMonth : Int -> List String
datesInMonth month =
    let
        count =
            if month == 2 then
                29

            else if List.member month [ 4, 6, 9, 11 ] then
                30

            else
                31
    in
    List.map (\day -> "2024-" ++ pad month ++ "-" ++ pad day) (List.range 1 count)


dates : List String
dates =
    List.concatMap datesInMonth (List.range 1 12)


indexOf : String -> Int
indexOf date =
    List.indexedMap Tuple.pair dates
        |> List.filter (Tuple.second >> (==) date)
        |> List.head
        |> Maybe.map Tuple.first
        |> Maybe.withDefault 0


monthOf : String -> Int
monthOf date =
    String.slice 5 7 date |> String.toInt |> Maybe.withDefault 1


monthBounds : Int -> ( String, String )
monthBounds month =
    ( "2024-" ++ pad month ++ "-01T00:00:00"
    , if month == 12 then
        "2025-01-01T00:00:00"

      else
        "2024-" ++ pad (month + 1) ++ "-01T00:00:00"
    )


aggregateMonth : Int -> Int -> List Measurement -> Result String (Dict String Daily)
aggregateMonth stationId month rows =
    let
        calendar =
            datesInMonth month

        grouped =
            List.foldl
                (\row -> Dict.update (String.left 10 row.timestamp) (\previous -> Just (row :: Maybe.withDefault [] previous)))
                Dict.empty
                rows

        validateDay date =
            Weather.validate stationId date (Dict.get date grouped |> Maybe.withDefault [])
                |> Result.map (daily date)
    in
    if List.any (\row -> String.length row.timestamp /= 19 || not (List.member (String.left 10 row.timestamp) calendar)) rows then
        Err "Die Monatsantwort enthält ein Datum außerhalb des angefragten UTC-Monats."

    else
        List.foldl
            (\date result ->
                Result.map2 (\value previous -> Dict.insert date value previous) (validateDay date) result
            )
            (Ok Dict.empty)
            calendar


daily : String -> List Measurement -> Daily
daily date rows =
    let
        values field =
            List.filterMap
                (\row ->
                    if row.quality == 0 then
                        Nothing

                    else
                        field row
                )
                rows

        temperatures =
            values .temperature

        humidities =
            values .humidity

        warning =
            List.any (\row -> row.quality /= 3) rows

        mean numbers =
            if List.length numbers == 144 && not warning then
                Just (List.sum numbers / 144)

            else
                Nothing

        occupied =
            rows
                |> List.filter (\row -> row.temperature /= Nothing && row.quality /= 0)
                |> List.map (Weather.minuteOfDay >> (\minute -> minute // 10))
                |> Set.fromList

        gap slot ( current, longest ) =
            if Set.member slot occupied then
                ( 0, longest )

            else
                ( current + 1, max longest (current + 1) )

        longestGap =
            List.foldl gap ( 0, 0 ) (List.range 0 143) |> Tuple.second
    in
    { date = date
    , rows = List.length rows
    , temperatureCount = List.length temperatures
    , humidityCount = List.length humidities
    , temperatureMean = mean temperatures
    , humidityMean = mean humidities
    , maxTemperatureGap = longestGap * 10
    , qualityWarning = warning
    , temperatureSlots = occupied
    }
