module Difference exposing (color, days, matching, monthErrors, name, palette)

import Dict exposing (Dict)
import Set exposing (Set)
import Weather
import Year


name : Int -> String
name stationId =
    Weather.stations |> List.filter (\station -> station.id == stationId) |> List.head |> Maybe.map .name |> Maybe.withDefault "Station"


palette : List ( String, String )
palette =
    [ ( "#2166ac", "≤ −10 °C" )
    , ( "#4393c3", "> −10 bis ≤ −5" )
    , ( "#92c5de", "> −5 bis ≤ −2" )
    , ( "#d1e5f0", "> −2 bis < 0" )
    , ( "#f7f7f7", "0 °C" )
    , ( "#fddbc7", "> 0 bis < 2" )
    , ( "#f4a582", "2 bis < 5" )
    , ( "#d6604d", "5 bis < 10" )
    , ( "#b2182b", "≥ 10 °C" )
    ]


color : Float -> String
color value =
    let
        index =
            if abs value < 0.000000001 then
                4

            else if value <= -10 then
                0

            else if value <= -5 then
                1

            else if value <= -2 then
                2

            else if value < 0 then
                3

            else if value < 2 then
                5

            else if value < 5 then
                6

            else if value < 10 then
                7

            else
                8
    in
    palette |> List.drop index |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault "#f7f7f7"


days : Int -> Int -> Dict Int (Dict String Year.Daily) -> Dict String Year.Daily
days stationA stationB source =
    let
        first =
            Dict.get stationA source |> Maybe.withDefault Dict.empty

        second =
            Dict.get stationB source |> Maybe.withDefault Dict.empty

        combine date =
            case ( Dict.get date first, Dict.get date second ) of
                ( Just a, Just b ) ->
                    let
                        common =
                            Set.intersect a.temperatureSlots b.temperatureSlots

                        gap slot ( current, longest ) =
                            if Set.member slot common then
                                ( 0, longest )

                            else
                                ( current + 1, max longest (current + 1) )

                        longestGap =
                            List.foldl gap ( 0, 0 ) (List.range 0 143) |> Tuple.second

                        mean =
                            if Set.size common == 144 then
                                Maybe.map2 (-) a.temperatureMean b.temperatureMean

                            else
                                Nothing
                    in
                    Just ( date, { a | temperatureMean = mean, temperatureCount = Set.size common, temperatureSlots = common, maxTemperatureGap = longestGap * 10, qualityWarning = a.qualityWarning || b.qualityWarning, humidityMean = Nothing, humidityCount = 0 } )

                _ ->
                    Nothing
    in
    List.filterMap combine Year.dates |> Dict.fromList


matching : Int -> Int -> Maybe (Set ( Int, String )) -> Maybe (Set ( Int, String ))
matching stationA stationB selection =
    selection |> Maybe.map (\selected -> Year.dates |> List.filter (\date -> Set.member ( stationA, date ) selected && Set.member ( stationB, date ) selected) |> List.map (Tuple.pair 0) |> Set.fromList)


monthErrors : Int -> Int -> Dict ( Int, Int ) String -> Dict ( Int, Int ) String
monthErrors stationA stationB errors =
    List.range 1 12
        |> List.filterMap
            (\month ->
                case ( Dict.get ( stationA, month ) errors, Dict.get ( stationB, month ) errors ) of
                    ( Just problem, _ ) ->
                        Just ( ( 0, month ), name stationA ++ ": " ++ problem )

                    ( _, Just problem ) ->
                        Just ( ( 0, month ), name stationB ++ ": " ++ problem )

                    _ ->
                        Nothing
            )
        |> Dict.fromList
