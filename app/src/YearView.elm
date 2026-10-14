module YearView exposing (Config, view)

import Array
import Dict exposing (Dict)
import Difference
import Html exposing (Html, a, button, div, h2, h3, p, span, text)
import Html.Attributes exposing (attribute, class, disabled, href, id, style, title, type_)
import Html.Events exposing (onClick, preventDefaultOn)
import Json.Decode as Decode
import Recursive
import Set exposing (Set)
import Weather exposing (Station)
import Year exposing (Daily)


type alias Config msg =
    { days : Dict Int (Dict String Daily)
    , done : Set ( Int, Int )
    , errors : Dict ( Int, Int ) String
    , active : Int
    , queued : Int
    , started : Bool
    , signedIn : Bool
    , selected : Set Int
    , selectedDay : Maybe String
    , focusIndex : Int
    , load : msg
    , choose : Int -> String -> msg
    , focus : Int -> Int -> msg
    , matching : Maybe (Set ( Int, String ))
    , stations : List Station
    , difference : Bool
    , range : Maybe ( String, String )
    , expanded : Set Int
    , expand : Int -> msg
    }


palette : List ( String, String )
palette =
    [ ( "#00224e", "< 0 °C" )
    , ( "#31446b", "0 bis < 5" )
    , ( "#666970", "5 bis < 10" )
    , ( "#929477", "10 bis < 15" )
    , ( "#bcb578", "15 bis < 20" )
    , ( "#e4d45a", "20 bis < 25" )
    , ( "#fee838", "≥ 25 °C" )
    ]


color : Float -> String
color number =
    palette |> List.drop (clamp 0 6 (floor (number / 5) + 1)) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault "#00224e"


rounded : Float -> String
rounded number =
    String.replace "." "," (String.fromFloat (toFloat (round (number * 100)) / 100))


view : Config msg -> Html msg
view config =
    div
        [ class "card annual"
        , id "annual"
        , attribute "data-difference"
            (if config.difference then
                "true"

             else
                "false"
            )
        ]
        [ h2 [] [ text "Jahresübersicht 2024 · Recursive Pattern" ]
        , p [ class "help" ]
            [ text
                (if config.difference then
                    "Jede Zelle zeigt die mittlere Temperaturdifferenz A minus B eines UTC-Tages. Sie erfordert dieselben 144 vorhandenen Zeitpunkte. Blau: A kälter; Rot: A wärmer; die Farbskala ist um 0 zentriert. Eine Fehlstelle in einer Station macht die vollständige Tagesdifferenz fehlend. Bei Profilfiltern müssen beide Stationsprofile passen."

                 else
                    "Jede Zelle ist ein UTC-Tag. Tagesmittel werden in Elm aus 144 Zehn-Minuten-Werten berechnet. Alle Stationen verwenden dieselben festen Farbbereiche."
                )
            ]
        , button [ id "load-year", type_ "button", disabled (not config.signedIn || config.active > 0 || config.queued > 0 || Set.size config.done == 48), onClick config.load ]
            [ text
                (if Set.size config.done == 48 then
                    "Jahresdaten vollständig geladen"

                 else if config.active > 0 || config.queued > 0 then
                    "Jahresdaten werden geladen …"

                 else if config.started then
                    "Fehlgeschlagene Monate erneut laden"

                 else
                    "Jahresdaten laden"
                )
            ]
        , p [ id "year-progress", attribute "role" "status", attribute "data-completed" (String.fromInt (Set.size config.done)), attribute "data-errors" (String.fromInt (Dict.size config.errors)) ]
            [ text
                (if not config.started then
                    "Jahresdaten noch nicht geladen."

                 else
                    String.fromInt (Set.size config.done) ++ " / 48 Stationsmonate geprüft · " ++ String.fromInt config.active ++ " aktive Anfragen · " ++ String.fromInt (Dict.size config.errors) ++ " Abruffehler"
                )
            ]
        , div
            [ class "year-legend"
            , attribute "aria-label"
                (if config.difference then
                    "Farbskala der Temperaturdifferenz A minus B"

                 else
                    "Farbskala der Temperatur-Tagesmittel"
                )
            ]
            (List.map (\( fill, label ) -> span [] [ span [ class "swatch", style "background" fill ] [], text label ])
                (if config.difference then
                    Difference.palette

                 else
                    palette
                )
                ++ [ span []
                        [ span [ class "swatch missing" ] []
                        , text
                            (if config.difference then
                                "Keine vollständige Tagesdifferenz"

                             else
                                "Kein vollständiges Tagesmittel"
                            )
                        ]
                   , span [] [ span [ class "swatch unloaded" ] [], text "Noch nicht geladen" ]
                   , span [] [ span [ class "swatch load-error" ] [], text "Abruffehler" ]
                   , span [] [ span [ class "swatch padding" ] [], text "Unbenutzter Platz" ]
                   ]
            )
        , p [ class "help" ] [ text "Leserichtung: innerhalb jedes Blocks zeilenweise von links nach rechts; dann zum nächsten Block. Ein Block umfasst sechs Wochen, keinen Kalendermonat. Zellen mit „1“ markieren Monatsanfänge. Klick oder Eingabetaste lädt den Tag im Temperaturdiagramm. Pfeiltasten bewegen den Fokus um einen Tag (links/rechts) oder sieben Tage (oben/unten)." ]
        , div [ class "reading-guide", attribute "aria-label" "Lesehilfe: Blöcke zeilenweise von links nach rechts, dann nach unten" ]
            [ div [ class "reading-blocks", attribute "aria-hidden" "true" ] (List.map (\row -> div [] [ text row ]) [ "1 → 2 → 3", "4 → 5 → 6", "7 → 8 → 9" ])
            , p [] [ text "Zuerst Block 1, dann 2 und 3; danach die nächste Blockzeile. Im Block: links nach rechts, anschließend eine Zeile nach unten. Monatsanfänge sind zusätzlich eingerahmt; die Datumsbereiche stehen über jedem Block." ]
            ]
        , p [] [ a [ href "#day-results" ] [ text "Zum Temperaturdiagramm des ausgewählten Tages" ] ]
        , div [ class "year-panels" ]
            (config.stations |> List.filter (\station -> Set.member station.id config.selected) |> List.map (panel config))
        , if Set.isEmpty config.selected then
            p [] [ text "Wähle mindestens eine Station für die Jahresübersicht." ]

          else
            text ""
        ]


panel : Config msg -> Station -> Html msg
panel config station =
    let
        stationDays =
            Dict.get station.id config.days |> Maybe.withDefault Dict.empty

        complete =
            Dict.values stationDays |> List.filter (\day -> day.temperatureMean /= Nothing) |> List.length

        coordinates =
            Recursive.positions [ Recursive.Level 3 3, Recursive.Level 7 6 ] |> Array.fromList

        calendar =
            Array.fromList Year.dates

        cell index =
            let
                ( x, y ) =
                    Array.get index coordinates |> Maybe.withDefault ( 0, 0 )

                positionAttributes =
                    [ attribute "data-index" (String.fromInt index), attribute "data-x" (String.fromInt x), attribute "data-y" (String.fromInt y) ]
            in
            case Array.get index calendar of
                Nothing ->
                    span (class "day-cell padding" :: attribute "aria-hidden" "true" :: positionAttributes) []

                Just date ->
                    let
                        value =
                            Dict.get date stationDays

                        error =
                            Dict.get ( station.id, Year.monthOf date ) config.errors

                        ( state, description, fill ) =
                            case value of
                                Nothing ->
                                    if error /= Nothing then
                                        ( "load-error", "Abruffehler: " ++ Maybe.withDefault "" error, Nothing )

                                    else
                                        ( "unloaded", "Monat noch nicht geladen", Nothing )

                                Just day ->
                                    let
                                        coverage =
                                            " · "
                                                ++ String.fromInt day.temperatureCount
                                                ++ (if config.difference then
                                                        "/144 gemeinsame Temperaturwerte"

                                                    else
                                                        "/144 Temperaturwerte"
                                                   )
                                                ++ " · längste Fehlstelle "
                                                ++ String.fromInt day.maxTemperatureGap
                                                ++ " Minuten"
                                    in
                                    case day.temperatureMean of
                                        Nothing ->
                                            ( "missing"
                                            , (if day.qualityWarning then
                                                "Abweichende Qualitätsklasse"

                                               else if config.difference then
                                                "Keine vollständige Tagesdifferenz"

                                               else
                                                "Kein vollständiges Tagesmittel"
                                              )
                                                ++ coverage
                                            , Nothing
                                            )

                                        Just mean ->
                                            ( "complete"
                                            , (if config.difference then
                                                "Mittlere Differenz "

                                               else
                                                "Tagesmittel "
                                              )
                                                ++ rounded mean
                                                ++ " °C"
                                                ++ coverage
                                            , Just
                                                ((if config.difference then
                                                    Difference.color

                                                  else
                                                    color
                                                 )
                                                    mean
                                                )
                                            )

                        descriptionText =
                            station.name ++ " · " ++ date ++ " (UTC) · " ++ description

                        keyDecoder =
                            Decode.field "key" Decode.string
                                |> Decode.andThen
                                    (\key ->
                                        case key of
                                            "ArrowRight" ->
                                                Decode.succeed ( config.focus station.id (min 365 (index + 1)), True )

                                            "ArrowLeft" ->
                                                Decode.succeed ( config.focus station.id (max 0 (index - 1)), True )

                                            "ArrowDown" ->
                                                Decode.succeed ( config.focus station.id (min 365 (index + 7)), True )

                                            "ArrowUp" ->
                                                Decode.succeed ( config.focus station.id (max 0 (index - 7)), True )

                                            _ ->
                                                Decode.fail "Andere Taste: natives Button-Verhalten"
                                    )
                    in
                    button
                        ([ class
                            ("day-cell "
                                ++ state
                                ++ (if String.right 2 date == "01" then
                                        " month-start"

                                    else
                                        ""
                                   )
                                ++ (if config.selectedDay == Just date then
                                        " chosen"

                                    else
                                        ""
                                   )
                            )
                         , id ("year-" ++ String.fromInt station.id ++ "-" ++ String.fromInt index)
                         , attribute "data-profile-match"
                            (config.matching
                                |> Maybe.map
                                    (\matching ->
                                        if Set.member ( station.id, date ) matching then
                                            "true"

                                        else
                                            "false"
                                    )
                                |> Maybe.withDefault "none"
                            )
                         , type_ "button"
                         , title descriptionText
                         , attribute "aria-label" descriptionText
                         , attribute "aria-pressed"
                            (if config.selectedDay == Just date then
                                "true"

                             else
                                "false"
                            )
                         , attribute "tabindex"
                            (if index == config.focusIndex then
                                "0"

                             else
                                "-1"
                            )
                         , attribute "data-date" date
                         , attribute "data-state" state
                         , attribute "data-mean" (value |> Maybe.andThen .temperatureMean |> Maybe.map String.fromFloat |> Maybe.withDefault "")
                         , attribute "data-count" (value |> Maybe.map (.temperatureCount >> String.fromInt) |> Maybe.withDefault "")
                         , attribute "data-humidity-mean" (value |> Maybe.andThen .humidityMean |> Maybe.map String.fromFloat |> Maybe.withDefault "")
                         , attribute "data-humidity-count" (value |> Maybe.map (.humidityCount >> String.fromInt) |> Maybe.withDefault "")
                         , attribute "data-gap" (value |> Maybe.map (.maxTemperatureGap >> String.fromInt) |> Maybe.withDefault "")
                         , attribute "data-in-range"
                            (config.range
                                |> Maybe.map
                                    (\( start, end ) ->
                                        if date >= start && date <= end then
                                            "true"

                                        else
                                            "false"
                                    )
                                |> Maybe.withDefault "none"
                            )
                         , onClick (config.choose station.id date)
                         , preventDefaultOn "keydown" keyDecoder
                         ]
                            ++ positionAttributes
                            ++ (fill |> Maybe.map (\background -> [ style "background-color" background ]) |> Maybe.withDefault [])
                        )
                        [ if String.right 2 date == "01" then
                            span
                                [ class "month-number"
                                , style "color"
                                    (if
                                        if config.difference then
                                            abs (value |> Maybe.andThen .temperatureMean |> Maybe.withDefault 0) >= 10

                                        else
                                            (value |> Maybe.andThen .temperatureMean |> Maybe.withDefault 15) < 10
                                     then
                                        "white"

                                     else
                                        "#17333e"
                                    )
                                ]
                                [ text "1" ]

                          else
                            text ""
                        ]

        block number =
            let
                start =
                    Array.get (number * 42) calendar |> Maybe.withDefault ""

                end =
                    Array.get (min 365 (number * 42 + 41)) calendar |> Maybe.withDefault ""
            in
            div [ class "year-block" ]
                [ p [ class "block-label" ] [ text ("Block " ++ String.fromInt (number + 1)), Html.br [] [], text (String.dropLeft 5 start ++ " – " ++ String.dropLeft 5 end) ]
                , div [ class "block-cells" ] (List.map cell (List.range (number * 42) (number * 42 + 41)))
                ]
    in
    div
        [ class
            (if Set.member station.id config.expanded then
                "year-panel expanded-panel"

             else
                "year-panel"
            )
        , attribute "data-year-station" (String.fromInt station.id)
        ]
        [ h3 [] [ span [ class "swatch", style "background" station.color ] [], text station.name ]
        , button
            [ type_ "button"
            , class "panel-size"
            , attribute "data-expand-station" (String.fromInt station.id)
            , attribute "aria-expanded"
                (if Set.member station.id config.expanded then
                    "true"

                 else
                    "false"
                )
            , onClick (config.expand station.id)
            ]
            [ text
                (if Set.member station.id config.expanded then
                    "Übersichtgröße"

                 else
                    "Panel vergrößern"
                )
            ]
        , p [ class "coverage", attribute "data-year-valid" (String.fromInt complete), attribute "data-year-days" (String.fromInt (Dict.size stationDays)) ]
            [ text
                (String.fromInt complete
                    ++ (if config.difference then
                            " vollständige Tagesdifferenzen · "

                        else
                            " vollständige Temperaturtage · "
                       )
                    ++ String.fromInt (Dict.size stationDays)
                    ++ " / 366 Tage geprüft"
                )
            ]
        , div [ class "recursive-blocks" ] (List.map block (List.range 0 8))
        ]
