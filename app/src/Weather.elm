module Weather exposing (Measurement, Station, dayBounds, decoder, minuteOfDay, stations, validate)

import Json.Decode as Decode exposing (Decoder)
import Set


type alias Station =
    { id : Int, name : String, color : String }


stations : List Station
stations =
    [ Station 5629 "Wittenberg" "#0072b2"
    , Station 2932 "Leipzig/Halle" "#d55e00"
    , Station 722 "Brocken" "#00856a"
    , Station 1975 "Hamburg-Fuhlsbuettel" "#9a61a4"
    ]


type alias Measurement =
    { stationId : Int
    , timestamp : String
    , temperature : Maybe Float
    , humidity : Maybe Float
    , quality : Int
    }


normalize : Maybe Float -> Maybe Float
normalize value =
    case value of
        Just number ->
            if number == -999 || number == -99.9 then
                Nothing

            else
                Just number

        Nothing ->
            Nothing


decoder : Decoder (List Measurement)
decoder =
    Decode.list
        (Decode.map5 Measurement
            (Decode.field "station_id" Decode.int)
            (Decode.field "timestamp" Decode.string)
            (Decode.field "lufttemperatur_c" (Decode.map normalize (Decode.nullable Decode.float)))
            (Decode.field "rel_feuchte_prozent" (Decode.map normalize (Decode.nullable Decode.float)))
            (Decode.field "quality_class_id" Decode.int)
        )


pad : Int -> String
pad number =
    String.padLeft 2 '0' (String.fromInt number)


monthDays : Int -> Int
monthDays month =
    if month == 2 then
        29

    else if List.member month [ 4, 6, 9, 11 ] then
        30

    else
        31


dayBounds : String -> Result String ( String, String )
dayBounds input =
    case List.map String.toInt (String.split "-" input) of
        [ Just 2024, Just month, Just day ] ->
            if month < 1 || month > 12 || day < 1 || day > monthDays month || input /= "2024-" ++ pad month ++ "-" ++ pad day then
                Err "Bitte wähle ein gültiges Datum im Jahr 2024."

            else
                let
                    next =
                        if day < monthDays month then
                            "2024-" ++ pad month ++ "-" ++ pad (day + 1)

                        else if month < 12 then
                            "2024-" ++ pad (month + 1) ++ "-01"

                        else
                            "2025-01-01"
                in
                Ok ( input ++ "T00:00:00", next ++ "T00:00:00" )

        _ ->
            Err "Bitte wähle ein gültiges Datum im Jahr 2024."


minuteOfDay : Measurement -> Int
minuteOfDay row =
    (String.slice 11 13 row.timestamp |> String.toInt |> Maybe.withDefault 0)
        * 60
        + (String.slice 14 16 row.timestamp |> String.toInt |> Maybe.withDefault 0)


validate : Int -> String -> List Measurement -> Result String (List Measurement)
validate stationId day rows =
    let
        validTimestamp row =
            let
                hour =
                    String.slice 11 13 row.timestamp |> String.toInt |> Maybe.withDefault -1

                minute =
                    String.slice 14 16 row.timestamp |> String.toInt |> Maybe.withDefault -1
            in
            row.timestamp
                == day
                ++ "T"
                ++ pad hour
                ++ ":"
                ++ pad minute
                ++ ":00"
                && hour
                >= 0
                && hour
                < 24
                && minute
                >= 0
                && minute
                < 60
                && modBy 10 minute
                == 0
                && String.slice 16 19 row.timestamp
                == ":00"
    in
    if List.length rows > 144 then
        Err "Der Server liefert mehr als 144 Zeitpunkte für diesen Tag."

    else if List.any (\row -> row.stationId /= stationId || not (validTimestamp row)) rows then
        Err "Station oder Zeitraster der Antwort stimmt nicht mit der Anfrage überein."

    else if Set.size (Set.fromList (List.map .timestamp rows)) /= List.length rows then
        Err "Die Antwort enthält doppelte Zeitstempel."

    else
        Ok (List.sortBy .timestamp rows)
