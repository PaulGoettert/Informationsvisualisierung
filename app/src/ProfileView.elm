module ProfileView exposing (Config, Point, axes, matches, points, view)

import Dict exposing (Dict)
import Html exposing (Html, button, div, h2, input, label, option, p, select, span, table, td, text, th, tr)
import Html.Attributes as HA exposing (attribute, class, disabled, id, style, type_, value)
import Html.Events exposing (on, onClick, onInput, preventDefaultOn)
import Json.Decode as Decode
import Profiles
import Set exposing (Set)
import Svg
import Svg.Attributes as SA
import Weather
import Year


type alias Point =
    { stationId : Int, date : String, values : List Float }


type alias Axis =
    { name : String, lower : Float, upper : Float, step : String }


axes : List Axis
axes =
    [ Axis "Temperatur °C" -15 30 "0.1", Axis "Feuchtigkeit %" 0 100 "1", Axis "Wind m/s" 0 30 "0.1", Axis "Niederschlag mm" 0 60 "0.1" ]


type alias Config msg =
    { model : Profiles.Model
    , yearDays : Dict Int (Dict String Year.Daily)
    , selected : Set Int
    , day : Maybe String
    , filters : Dict Int ( Float, Float )
    , canLoad : Bool
    , load : msg
    , filter : Int -> Bool -> String -> msg
    , reset : msg
    , choose : Int -> String -> msg
    , range : Maybe ( String, String )
    , mode : String
    , display : String -> msg
    , query : String
    , search : String -> msg
    }


points : Dict Int (Dict String Year.Daily) -> Profiles.Model -> List Point
points days model =
    List.concatMap
        (\station ->
            Dict.get station.id days
                |> Maybe.withDefault Dict.empty
                |> Dict.values
                |> List.filterMap
                    (\day ->
                        case ( day.temperatureMean, day.humidityMean, Dict.get ( station.id, 0, day.date ) model.stats |> Maybe.andThen .value ) of
                            ( Just temperature, Just humidity, Just wind ) ->
                                Dict.get ( station.id, 1, day.date ) model.stats
                                    |> Maybe.andThen .value
                                    |> Maybe.map (\rain -> Point station.id day.date [ temperature, humidity, wind, rain ])

                            _ ->
                                Nothing
                    )
        )
        Weather.stations


matches : Dict Int ( Float, Float ) -> Point -> Bool
matches filters point =
    List.indexedMap Tuple.pair point.values
        |> List.all (\( index, number ) -> Dict.get index filters |> Maybe.map (\( low, high ) -> number >= low && number <= high) |> Maybe.withDefault True)


format : Float -> String
format number =
    String.replace "." "," (String.fromFloat (toFloat (round (number * 100)) / 100))


view : Config msg -> Html msg
view config =
    let
        all =
            points config.yearDays config.model

        visible =
            List.filter (\point -> Set.member point.stationId config.selected && (config.range |> Maybe.map (\( start, end ) -> point.date >= start && point.date <= end) |> Maybe.withDefault True)) all

        matching =
            List.filter (matches config.filters) visible

        drawn =
            case config.mode of
                "matching" ->
                    matching

                "day" ->
                    List.filter (\point -> Just point.date == config.day) matching

                _ ->
                    visible

        searchable point =
            let
                station =
                    Weather.stations |> List.filter (\item -> item.id == point.stationId) |> List.head |> Maybe.map .name |> Maybe.withDefault ""

                content =
                    String.toLower (station ++ " " ++ point.date ++ " " ++ (String.split "-" point.date |> List.reverse |> String.join "."))
            in
            String.words (String.toLower config.query) |> List.all (\word -> String.contains word content)

        selectable =
            List.filter searchable matching

        checked =
            List.sum (List.map (\station -> Year.dates |> List.filter (\date -> (config.range |> Maybe.map (\( start, end ) -> date >= start && date <= end) |> Maybe.withDefault True) && Dict.member ( station.id, 0, date ) config.model.stats && Dict.member ( station.id, 1, date ) config.model.stats && (Dict.get station.id config.yearDays |> Maybe.map (Dict.member date) |> Maybe.withDefault False)) |> List.length) (List.filter (\station -> Set.member station.id config.selected) Weather.stations))

        complete =
            Set.size config.model.done == 96

        control index axis =
            let
                ( low, high ) =
                    Dict.get index config.filters |> Maybe.withDefault ( axis.lower, axis.upper )

                slider isLow number =
                    label []
                        [ text
                            ((if isLow then
                                "Von "

                              else
                                "Bis "
                             )
                                ++ format number
                            )
                        , input
                            [ id
                                ("filter-"
                                    ++ String.fromInt index
                                    ++ (if isLow then
                                            "-min"

                                        else
                                            "-max"
                                       )
                                )
                            , type_ "range"
                            , HA.min (String.fromFloat axis.lower)
                            , HA.max (String.fromFloat axis.upper)
                            , HA.step axis.step
                            , value (String.fromFloat number)
                            , disabled (not complete)
                            , onInput (config.filter index isLow)
                            ]
                            []
                        ]
            in
            div [ class "axis-filter" ] [ p [] [ text axis.name ], slider True low, slider False high ]
    in
    div [ class "card profiles", id "profiles" ]
        [ h2 [] [ text "Wetterprofile · parallele Koordinaten" ]
        , p [ class "help" ] [ text "Eine Linie verbindet vier vollständige Tageskennzahlen derselben Station. Temperatur, Feuchtigkeit und Wind sind Mittel; Niederschlag ist die Summe veröffentlichter Intervalle. Wind und Niederschlag umfassen 00:10 Uhr bis einschließlich Mitternacht des Folgetags (UTC). Die gerätebedingte Zeitunsicherheit des Niederschlags bleibt bestehen." ]
        , button [ id "load-profiles", type_ "button", onClick config.load, disabled (not config.canLoad || not (Dict.isEmpty config.model.active) || complete) ]
            [ text
                (if complete then
                    "Wetterprofile vollständig geladen"

                 else if config.model.started then
                    "Fehlende Wetterdaten erneut laden"

                 else
                    "Wind und Niederschlag laden"
                )
            ]
        , p [ id "profile-progress", attribute "role" "status", attribute "data-completed" (String.fromInt (Set.size config.model.done)), attribute "data-errors" (String.fromInt (Dict.size config.model.errors)) ]
            [ text
                (String.fromInt (Set.size config.model.done)
                    ++ " / 96 Feld-/Stationsmonate geprüft · "
                    ++ String.fromInt (Dict.size config.model.errors)
                    ++ " Abruffehler."
                    ++ (if config.canLoad then
                            ""

                        else
                            " Zuerst die Temperatur-Jahresdaten laden."
                       )
                )
            ]
        , div [ class "year-legend" ]
            (Weather.stations |> List.filter (\station -> Set.member station.id config.selected) |> List.map (\station -> span [] [ span [ class "swatch", style "background" station.color ] [], text station.name ]))
        , p [ id "profile-count", attribute "data-total" (String.fromInt (List.length visible)), attribute "data-matching" (String.fromInt (List.length matching)), attribute "data-excluded" (String.fromInt (checked - List.length visible)) ]
            [ text (String.fromInt (List.length matching) ++ " passende von " ++ String.fromInt (List.length visible) ++ " vollständigen Profilen · " ++ String.fromInt (checked - List.length visible) ++ " geprüfte Tage wegen unvollständiger Kennzahlen oder Qualitätsabweichung ausgeschlossen") ]
        , p [ class "help" ] [ text "Grenzen unter den Achsen filtern gemeinsam (UND). Passende Tage bleiben in der Jahresübersicht hervorgehoben; unpassende Tage und Temperaturreihen werden abgeblendet. Rohwerte bleiben sichtbar. Klick auf eine Linie lädt den Tag. Die Skalen bleiben beim Filtern unverändert." ]
        , label [ class "field" ] [ span [] [ text "Profildarstellung" ], select [ id "profile-display", value config.mode, onInput config.display ] [ option [ value "all" ] [ text "Gesamtkontext" ], option [ value "matching" ] [ text "Nur passende Profile" ], option [ value "day" ] [ text "Ausgewählter Tag · passende Profile" ] ] ]
        , p [ id "profile-drawn", attribute "role" "status", attribute "data-drawn" (String.fromInt (List.length drawn)) ] [ text (String.fromInt (List.length drawn) ++ " gezeichnete Profile. Darstellungswahl verändert weder Wetterfilter noch Trefferzahl.") ]
        , div [ class "chart" ] [ chart config drawn ]
        , div [ class "profile-filter-grid" ] (List.indexedMap control axes)
        , button [ id "reset-filters", type_ "button", onClick config.reset, disabled (Dict.isEmpty config.filters && String.isEmpty config.query && config.mode == "all") ] [ text "Profilfilter zurücksetzen" ]
        , label [ class "field" ]
            [ span [] [ text "Profilauswahl nach Station oder Datum durchsuchen" ]
            , input [ id "profile-search", type_ "search", value config.query, onInput config.search, HA.placeholder "z. B. Brocken 2024-01 oder 22.01.2024", attribute "aria-describedby" "profile-search-status" ] []
            ]
        , p [ id "profile-search-status", class "help", attribute "role" "status" ]
            [ text (String.fromInt (List.length selectable) ++ " von " ++ String.fromInt (List.length matching) ++ " passenden Profilen in der Auswahlliste. Die Suche verändert nur die Liste; Wetterfilter und Diagramme bleiben erhalten.") ]
        , label [ class "field" ]
            [ span [] [ text "Passendes Tagesprofil öffnen" ]
            , select
                [ id "profile-picker"
                , disabled (List.isEmpty selectable)
                , value
                    (selectable
                        |> List.filter (\point -> Just point.date == config.day)
                        |> List.head
                        |> Maybe.map (\point -> String.fromInt point.stationId ++ "/" ++ point.date)
                        |> Maybe.withDefault ""
                    )
                , on "change"
                    (Decode.at [ "target", "value" ] Decode.string
                        |> Decode.andThen
                            (\key ->
                                case String.split "/" key of
                                    [ station, date ] ->
                                        case String.toInt station of
                                            Just stationId ->
                                                Decode.succeed (config.choose stationId date)

                                            Nothing ->
                                                Decode.fail "Ungültige Station"

                                    _ ->
                                        Decode.fail "Kein Profil ausgewählt"
                            )
                    )
                ]
                (option [ value "", disabled True, HA.selected True ]
                    [ text
                        (if List.isEmpty selectable then
                            "Keine Profile für diese Auswahl oder Suche"

                         else
                            "Station und Datum wählen"
                        )
                    ]
                    :: List.map
                        (\point ->
                            option [ value (String.fromInt point.stationId ++ "/" ++ point.date) ]
                                [ text ((Weather.stations |> List.filter (\station -> station.id == point.stationId) |> List.head |> Maybe.map .name |> Maybe.withDefault "Station") ++ " · " ++ point.date) ]
                        )
                        selectable
                )
            ]
        , if complete && List.isEmpty matching then
            p [ class "feedback", attribute "role" "status" ] [ text "Keine vollständigen Profile erfüllen die aktive Auswahl. Filter zurücksetzen oder Stationen auswählen." ]

          else
            text ""
        , detail config
        ]


chart : Config msg -> List Point -> Html msg
chart config visible =
    let
        x index =
            95 + toFloat index * 260

        y axis number =
            275 - (number - axis.lower) / (axis.upper - axis.lower) * 210

        axisView index axis =
            Svg.g []
                ([ Svg.line [ SA.x1 (String.fromFloat (x index)), SA.x2 (String.fromFloat (x index)), SA.y1 "65", SA.y2 "275", SA.stroke "#526d79" ] []
                 , Svg.text_ [ SA.x (String.fromFloat (x index)), SA.y "35", SA.textAnchor "middle", SA.fontSize "20" ] [ Svg.text axis.name ]
                 ]
                    ++ List.map
                        (\tick ->
                            let
                                number =
                                    axis.lower + toFloat tick / 4 * (axis.upper - axis.lower)
                            in
                            Svg.text_ [ SA.x (String.fromFloat (x index - 7)), SA.y (String.fromFloat (y axis number + 4)), SA.textAnchor "end", SA.fontSize "18" ] [ Svg.text (format number) ]
                        )
                        (List.range 0 4)
                )

        draw point =
            let
                station =
                    Weather.stations |> List.filter (\item -> item.id == point.stationId) |> List.head

                selected =
                    config.day == Just point.date

                matching =
                    matches config.filters point

                coordinates =
                    List.map2 Tuple.pair axes point.values |> List.indexedMap (\index ( axis, number ) -> String.fromFloat (x index) ++ "," ++ String.fromFloat (y axis number)) |> String.join " "

                label =
                    (station |> Maybe.map .name |> Maybe.withDefault "") ++ " · " ++ point.date ++ " · " ++ String.join " / " (List.map format point.values)

                keyboard =
                    Decode.field "key" Decode.string
                        |> Decode.andThen
                            (\key ->
                                if key == "Enter" || key == " " then
                                    Decode.succeed ( config.choose point.stationId point.date, True )

                                else
                                    Decode.fail "Andere Taste"
                            )
            in
            Svg.polyline
                [ SA.points coordinates
                , SA.fill "none"
                , SA.stroke
                    (if matching then
                        station |> Maybe.map .color |> Maybe.withDefault "#526d79"

                     else
                        "#a6b3bb"
                    )
                , SA.strokeWidth
                    (if selected then
                        "3"

                     else
                        "1"
                    )
                , SA.opacity
                    (if selected && matching then
                        "1"

                     else if matching then
                        "0.2"

                     else
                        "0.04"
                    )
                , attribute "data-profile-station" (String.fromInt point.stationId)
                , attribute "data-profile-date" point.date
                , attribute "data-values" (String.join "," (List.map String.fromFloat point.values))
                , attribute "data-match"
                    (if matching then
                        "true"

                     else
                        "false"
                    )
                , attribute "role" "button"
                , attribute "aria-label" label
                , attribute "tabindex"
                    (if selected then
                        "0"

                     else
                        "-1"
                    )
                , onClick (config.choose point.stationId point.date)
                , preventDefaultOn "keydown" keyboard
                , style "cursor" "pointer"
                ]
                [ Svg.title [] [ Svg.text label ] ]

        ordered =
            List.filter (\point -> config.day /= Just point.date) visible ++ List.filter (\point -> config.day == Just point.date) visible
    in
    Svg.svg [ SA.viewBox "0 0 1000 310", attribute "aria-label" "Vier Achsen mit vollständigen Tagesprofilen" ]
        (List.map draw ordered ++ List.indexedMap axisView axes)


detail : Config msg -> Html msg
detail config =
    let
        date =
            config.day |> Maybe.withDefault "2024-07-15"

        field number count gap =
            (number |> Maybe.map format |> Maybe.withDefault "Nicht verfügbar")
                ++ " · "
                ++ String.fromInt count
                ++ "/144"
                ++ (if gap > 0 then
                        " · Lücke " ++ String.fromInt gap ++ " min"

                    else
                        ""
                   )

        row station =
            let
                day =
                    Dict.get station.id config.yearDays |> Maybe.andThen (Dict.get date)

                stat kind =
                    Dict.get ( station.id, kind, date ) config.model.stats

                interval kind =
                    stat kind
                        |> Maybe.map (\value -> field value.value value.count value.gap)
                        |> Maybe.withDefault
                            (Dict.get ( station.id, Year.monthOf date, kind ) config.model.errors |> Maybe.map ((++) "Abruffehler: ") |> Maybe.withDefault "Noch nicht geladen")

                intervalCell kind =
                    td
                        [ attribute "data-stat-station" (String.fromInt station.id)
                        , attribute "data-stat-kind" (String.fromInt kind)
                        , attribute "data-stat-date" date
                        , attribute "data-stat-value" (stat kind |> Maybe.andThen .value |> Maybe.map String.fromFloat |> Maybe.withDefault "")
                        , attribute "data-stat-count" (stat kind |> Maybe.map (.count >> String.fromInt) |> Maybe.withDefault "")
                        , attribute "data-stat-gap" (stat kind |> Maybe.map (.gap >> String.fromInt) |> Maybe.withDefault "")
                        ]
                        [ text
                            (interval kind
                                ++ (if stat kind |> Maybe.map .qualityWarning |> Maybe.withDefault False then
                                        " · Qualitätsabweichung"

                                    else
                                        ""
                                   )
                            )
                        ]
            in
            tr [] [ td [] [ text station.name ], td [] [ text (day |> Maybe.map (\value -> field value.temperatureMean value.temperatureCount value.maxTemperatureGap) |> Maybe.withDefault "Noch nicht geladen") ], td [] [ text (day |> Maybe.map (\value -> field value.humidityMean value.humidityCount 0) |> Maybe.withDefault "Noch nicht geladen") ], intervalCell 0, intervalCell 1 ]
    in
    div [ class "table-container" ]
        [ p [] [ text ("Tageskennzahlen am " ++ date ++ " (UTC)") ]
        , table []
            [ tr [] (List.map (\heading -> th [] [ text heading ]) [ "Station", "Temperatur °C", "Feuchtigkeit %", "Wind m/s", "Niederschlag mm" ])
            , Html.tbody [] (Weather.stations |> List.filter (\station -> Set.member station.id config.selected) |> List.map row)
            ]
        ]
