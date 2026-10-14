module RangeView exposing (Config, view)

import Dict exposing (Dict)
import Html exposing (Html, div, h2, p, span, table, td, text, th, tr)
import Html.Attributes exposing (attribute, class, style)
import Range
import Set exposing (Set)
import Svg
import Svg.Attributes as SA
import Weather
import Year


type alias Config =
    { range : Range.Model, days : Dict Int (Dict String Year.Daily), matching : Maybe (Set ( Int, String )) }


type alias Sample =
    { date : String, offset : Int, value : Maybe Float }


samples : Config -> Int -> List Sample
samples config stationId =
    let
        daySamples index date =
            if config.range.raw then
                case Dict.get ( stationId, date ) config.range.results of
                    Just (Ok rows) ->
                        List.map
                            (\row ->
                                Sample date
                                    (index * 1440 + Weather.minuteOfDay row)
                                    (if row.quality == 0 then
                                        Nothing

                                     else
                                        row.temperature
                                    )
                            )
                            rows

                    _ ->
                        [ Sample date (index * 1440) Nothing ]

            else
                [ Sample date (index * 1440 + 720) (Dict.get stationId config.days |> Maybe.andThen (Dict.get date) |> Maybe.andThen .temperatureMean) ]
    in
    List.indexedMap daySamples config.range.dates |> List.concat


segments : Int -> List Sample -> List (List Sample)
segments spacing rows =
    let
        step row ( current, finished ) =
            if row.value == Nothing then
                ( []
                , if List.isEmpty current then
                    finished

                  else
                    List.reverse current :: finished
                )

            else
                case current of
                    previous :: _ ->
                        if row.offset - previous.offset == spacing then
                            ( row :: current, finished )

                        else
                            ( [ row ], List.reverse current :: finished )

                    [] ->
                        ( [ row ], finished )

        ( last, completed ) =
            List.foldl step ( [], [] ) rows
    in
    List.reverse
        (if List.isEmpty last then
            completed

         else
            List.reverse last :: completed
        )


format : Float -> String
format number =
    String.replace "." "," (String.fromFloat (toFloat (round (number * 100)) / 100))


view : Config -> Html msg
view config =
    let
        range =
            config.range

        series =
            Weather.stations |> List.filter (\station -> List.member station.id range.stations) |> List.map (\station -> ( station, samples config station.id ))

        values =
            series |> List.concatMap (Tuple.second >> List.filterMap .value)

        low =
            toFloat (floor (Maybe.withDefault 0 (List.minimum values) / 5)) * 5 - 2

        high =
            toFloat (ceiling (Maybe.withDefault 25 (List.maximum values) / 5)) * 5 + 2

        spacing =
            if range.raw then
                10

            else
                1440

        x minute =
            65 + toFloat minute / toFloat (List.length range.dates * 1440) * 895

        y value =
            260 - (value - low) / (high - low) * 220

        point sample =
            String.fromFloat (x sample.offset) ++ "," ++ String.fromFloat (y (Maybe.withDefault low sample.value))

        parts station rows opacity layer =
            Svg.g [ attribute "data-range-series" (String.fromInt station.id), attribute "data-layer" layer, SA.opacity opacity ]
                (segments spacing rows
                    |> List.map
                        (\part ->
                            case part of
                                [ sample ] ->
                                    Svg.circle [ SA.cx (String.fromFloat (x sample.offset)), SA.cy (String.fromFloat (y (Maybe.withDefault low sample.value))), SA.r "3", SA.fill station.color ] []

                                _ ->
                                    Svg.polyline [ SA.points (String.join " " (List.map point part)), SA.stroke station.color, SA.strokeWidth "2", SA.fill "none" ] []
                        )
                )

        draw ( station, rows ) =
            [ parts station
                rows
                (if config.matching == Nothing then
                    "1"

                 else
                    "0.15"
                )
                "context"
            ]
                ++ (case config.matching of
                        Nothing ->
                            []

                        Just matching ->
                            [ parts station
                                (List.map
                                    (\sample ->
                                        if Set.member ( station.id, sample.date ) matching then
                                            sample

                                        else
                                            { sample | value = Nothing }
                                    )
                                    rows
                                )
                                "1"
                                "matching"
                            ]
                   )

        tick index =
            let
                value =
                    low + toFloat index / 4 * (high - low)
            in
            Svg.g [] [ Svg.line [ SA.x1 "65", SA.x2 "960", SA.y1 (String.fromFloat (y value)), SA.y2 (String.fromFloat (y value)), SA.stroke "#e2e8ee" ] [], Svg.text_ [ SA.x "53", SA.y (String.fromFloat (y value + 4)), SA.textAnchor "end", SA.fontSize "18" ] [ Svg.text (format value) ] ]

        tickIndices =
            List.range 0 (List.length range.dates - 1) |> List.filter (\index -> index == 0 || index == List.length range.dates - 1 || modBy (max 1 (List.length range.dates // 5)) index == 0)

        label index =
            Svg.text_
                [ SA.x
                    (String.fromFloat
                        (x
                            (index
                                * 1440
                                + (if range.raw then
                                    0

                                   else
                                    720
                                  )
                            )
                        )
                    )
                , SA.y "283"
                , SA.textAnchor "middle"
                , SA.fontSize "16"
                ]
                [ Svg.text (List.drop index range.dates |> List.head |> Maybe.map (String.dropLeft 5) |> Maybe.withDefault "") ]

        errors =
            Dict.toList range.results
                |> List.filterMap
                    (\( ( stationId, date ), result ) ->
                        case result of
                            Err message ->
                                Just (differenceName stationId ++ " · " ++ date ++ ": " ++ message)

                            Ok _ ->
                                Nothing
                    )

        summary ( station, rows ) =
            tr []
                [ td [] [ span [ class "swatch", style "background" station.color ] [], text station.name ]
                , td [ attribute "data-range-count" (String.fromInt station.id) ]
                    [ text
                        (String.fromInt (List.length (List.filterMap .value rows))
                            ++ " / "
                            ++ String.fromInt
                                (List.length range.dates
                                    * (if range.raw then
                                        144

                                       else
                                        1
                                      )
                                )
                        )
                    ]
                ]
    in
    if not range.started then
        text ""

    else
        div
            [ class "card"
            , attribute "id" "range-results"
            , attribute "data-resolution"
                (if range.raw then
                    "raw"

                 else
                    "daily"
                )
            , attribute "data-days" (String.fromInt (List.length range.dates))
            , attribute "data-start" range.start
            , attribute "data-end" range.end
            ]
            [ h2 [] [ text ("Temperaturen vom " ++ range.start ++ " bis " ++ range.end ++ " · UTC") ]
            , p [ class "help" ]
                [ text
                    (if range.raw then
                        "Zehn-Minuten-Werte · bis einschließlich sieben Tage · gemeinsame Temperaturskala"

                     else
                        "Tagesmittel · mehr als sieben Tage · Punkte in der Tagesmitte · gemeinsame Temperaturskala"
                    )
                ]
            , p [ attribute "role" "status", attribute "id" "range-progress", attribute "data-completed" (String.fromInt (Dict.size range.results)) ]
                [ text
                    (if range.raw then
                        String.fromInt (Dict.size range.results) ++ " / " ++ String.fromInt (List.length range.dates * List.length range.stations) ++ " Stations-/Tagesabrufe abgeschlossen"

                     else
                        "Geprüfte Tagesmittel aus dem Jahresabruf; keine zusätzlichen Rohwertanfragen."
                    )
                ]
            , div [ class "error" ] (List.map (\message -> p [] [ text message ]) errors)
            , if List.isEmpty values then
                p [] [ text "Keine verwendbaren Temperaturwerte im geladenen Zeitraum." ]

              else
                div [ class "chart" ]
                    [ Svg.svg [ SA.viewBox "0 0 1000 310", attribute "role" "img", attribute "aria-label" "Temperaturvergleich im ausgewählten UTC-Zeitraum" ]
                        (List.map tick (List.range 0 4) ++ List.map label tickIndices ++ List.concatMap draw series ++ [ Svg.text_ [ SA.x "18", SA.y "25", SA.fontSize "18" ] [ Svg.text "°C" ], Svg.text_ [ SA.x "510", SA.y "306", SA.textAnchor "middle", SA.fontSize "18" ] [ Svg.text "Datum (UTC)" ] ])
                    ]
            , table []
                [ tr []
                    [ th [] [ text "Station" ]
                    , th []
                        [ text
                            (if range.raw then
                                "Vorhandene Temperaturwerte"

                             else
                                "Vollständige Temperaturtage"
                            )
                        ]
                    ]
                , Html.tbody [] (List.map summary series)
                ]
            , p [ class "help" ] [ text "Die Zeitraumwahl grenzt Wetterprofile ein und markiert die Jahresübersicht. Fehlstellen bleiben offen. Profilfilter verändern die Hervorhebung, erhalten aber den Zeitverlauf als Kontext; nicht benachbarte passende Tage werden nicht verbunden." ]
            ]


differenceName : Int -> String
differenceName stationId =
    Weather.stations |> List.filter (\station -> station.id == stationId) |> List.head |> Maybe.map .name |> Maybe.withDefault "Station"
