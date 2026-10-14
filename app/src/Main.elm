module Main exposing (main)

import Api
import Browser
import Browser.Dom
import DailyCache
import Dict exposing (Dict)
import Difference
import Html exposing (Html, button, div, form, h1, h2, input, label, main_, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (attribute, class, disabled, id, name, required, style, type_, value)
import Html.Events exposing (onCheck, onClick, onInput, onSubmit)
import Http
import Process
import ProfileView
import Profiles
import Range
import RangeView
import Set exposing (Set)
import Svg
import Svg.Attributes as SA
import Task
import Weather exposing (Measurement, Station)
import Year
import YearView


type alias Flags =
    { apiBase : String }


type Session
    = LoggedOut
    | LoggingIn
    | SignedIn String
    | AuthError String


type Series
    = Pending
    | Ready (List Measurement)
    | Failed String


type alias YearJob =
    { stationId : Int, month : Int }


type alias PageBuffer =
    { rows : List Measurement, pages : Int }


type alias Model =
    { apiBase : String
    , username : String
    , password : String
    , session : Session
    , dateInput : String
    , requestDay : Maybe String
    , selected : Set Int
    , results : Dict Int Series
    , generation : Int
    , feedback : String
    , yearDays : Dict Int (Dict String Year.Daily)
    , yearDone : Set ( Int, Int )
    , yearErrors : Dict ( Int, Int ) String
    , yearActive : Dict ( Int, Int ) PageBuffer
    , yearQueue : List YearJob
    , yearGeneration : Int
    , yearStarted : Bool
    , yearFocus : Int
    , profiles : Profiles.Model
    , filters : Dict Int ( Float, Float )
    , profileQuery : String
    , profileMode : String
    , expandedPanels : Set Int
    , dayCache : DailyCache.Model
    , stationRevision : Int
    , range : Range.Model
    , rangeStart : String
    , rangeEnd : String
    , difference : Bool
    , stationA : Int
    , stationB : Int
    }


type Msg
    = UsernameChanged String
    | PasswordChanged String
    | Login
    | GotToken Int (Result Http.Error String)
    | Logout
    | DateChanged String
    | StationChanged Int Bool
    | Load
    | ForceLoad
    | ForceRange
    | CommitStations Int
    | ProfileMode String
    | ExpandPanel Int
    | GotMeasurements Int Int String (Result Http.Error (List Measurement))
    | LoadYear
    | GotYearPage Int Int Int Int (Result Http.Error (List Measurement))
    | ChooseYearDay Int String
    | FocusYearDay Int Int
    | FocusFinished (Result Browser.Dom.Error ())
    | LoadProfiles
    | ProfileMessage Profiles.Msg
    | ProfileFilter Int Bool String
    | ResetFilters
    | ProfileQuery String
    | RangeStart String
    | RangeEnd String
    | ApplyRange
    | RangeMessage Range.Msg
    | DifferenceMode Bool
    | PairChanged Bool String
    | ResetSelection


main : Program Flags Model Msg
main =
    Browser.element { init = init, update = update, subscriptions = \_ -> Sub.none, view = view }


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { apiBase = flags.apiBase
      , username = ""
      , password = ""
      , session = LoggedOut
      , dateInput = "2024-07-15"
      , requestDay = Nothing
      , selected = Set.fromList (List.map .id Weather.stations)
      , results = Dict.empty
      , generation = 0
      , feedback = ""
      , yearDays = Dict.empty
      , yearDone = Set.empty
      , yearErrors = Dict.empty
      , yearActive = Dict.empty
      , yearQueue = []
      , yearGeneration = 0
      , yearStarted = False
      , yearFocus = Year.indexOf "2024-07-15"
      , profiles = Profiles.init
      , filters = Dict.empty
      , profileQuery = ""
      , profileMode = "all"
      , expandedPanels = Set.empty
      , dayCache = DailyCache.empty
      , stationRevision = 0
      , range = Range.init
      , rangeStart = "2024-07-15"
      , rangeEnd = "2024-07-15"
      , difference = False
      , stationA = 5629
      , stationB = 722
      }
    , Cmd.none
    )


httpError : Http.Error -> String
httpError error =
    case error of
        Http.BadStatus 401 ->
            "Der Zugang wurde abgelehnt oder ist abgelaufen. Bitte melde dich erneut an."

        Http.BadStatus 403 ->
            "Für diese Anfrage fehlt die Zugriffsberechtigung. Bitte prüfe deinen Veranstaltungszugang."

        Http.BadStatus code ->
            "Der Server antwortet mit HTTP " ++ String.fromInt code ++ ". Bitte versuche es erneut."

        Http.Timeout ->
            "Die Anfrage hat zu lange gedauert. Bitte versuche es erneut."

        Http.NetworkError ->
            "Der Datenserver ist nicht erreichbar. Prüfe Verbindung und Serverzugriff."

        Http.BadBody _ ->
            "Die Serverantwort hat nicht das erwartete Datenformat."

        Http.BadUrl _ ->
            "Die Datenadresse ist ungültig."


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        UsernameChanged username ->
            ( { model | username = username }, Cmd.none )

        PasswordChanged password ->
            ( { model | password = password }, Cmd.none )

        Login ->
            if String.isEmpty (String.trim model.username) || String.isEmpty model.password then
                ( { model | session = AuthError "Bitte gib Benutzername und Passwort aus der Veranstaltung ein." }, Cmd.none )

            else
                let
                    generation =
                        model.generation + 1
                in
                ( resetYear { model | session = LoggingIn, generation = generation, results = Dict.empty, requestDay = Nothing }
                , Api.login model.apiBase (String.trim model.username) model.password (GotToken generation)
                )

        GotToken generation result ->
            if generation /= model.generation then
                ( model, Cmd.none )

            else
                case result of
                    Ok token ->
                        if String.isEmpty token then
                            ( { model | session = AuthError "Der Server hat keinen gültigen Zugang geliefert.", password = "" }, Cmd.none )

                        else
                            update Load { model | session = SignedIn token, password = "", feedback = "" }

                    Err error ->
                        ( { model | session = AuthError (httpError error), password = "" }, Cmd.none )

        Logout ->
            ( resetYear { model | session = LoggedOut, password = "", results = Dict.empty, requestDay = Nothing, generation = model.generation + 1, feedback = "" }, Cmd.none )

        DateChanged day ->
            ( { model | dateInput = day, yearFocus = Year.indexOf day }, Cmd.none )

        StationChanged stationId active ->
            let
                selected =
                    if active then
                        Set.insert stationId model.selected

                    else
                        Set.remove stationId model.selected

                revision =
                    model.stationRevision + 1

                oldRange =
                    model.range

                paused =
                    { oldRange | generation = model.range.generation + 1, stations = Set.toList selected, active = Set.empty, queue = [], results = Dict.filter (\( station, _ ) _ -> Set.member station selected) model.range.results }

                next =
                    { model | selected = selected, stationRevision = revision, generation = model.generation + 1, results = Dict.filter (\station _ -> Set.member station selected) model.results, range = paused, feedback = "Stationsauswahl wird übernommen …" }
            in
            if Set.isEmpty selected then
                ( { next | results = Dict.empty, range = Range.reset paused, feedback = "Bitte wähle mindestens eine Station." }, Cmd.none )

            else
                ( next, Process.sleep 250 |> Task.perform (\_ -> CommitStations revision) )

        CommitStations revision ->
            if revision /= model.stationRevision then
                ( model, Cmd.none )

            else
                case model.session of
                    SignedIn token ->
                        let
                            ( range, rangeCommand ) =
                                case Range.bounds model.range of
                                    Just ( first, last ) ->
                                        Range.load model.apiBase token first last (Set.toList model.selected) model.range |> Result.withDefault ( model.range, Cmd.none )

                                    Nothing ->
                                        ( model.range, Cmd.none )

                            ( next, command ) =
                                update Load { model | range = range, dateInput = Maybe.withDefault model.dateInput model.requestDay }
                        in
                        ( { next | dateInput = model.dateInput }, Cmd.batch [ command, Cmd.map RangeMessage rangeCommand ] )

                    _ ->
                        ( model, Cmd.none )

        ForceLoad ->
            update Load { model | dayCache = DailyCache.empty }

        ForceRange ->
            case Range.bounds model.range of
                Just ( first, last ) ->
                    let
                        ( next, command ) =
                            update ApplyRange { model | dayCache = DailyCache.empty, range = Range.clearCache model.range, rangeStart = first, rangeEnd = last }
                    in
                    ( { next | rangeStart = model.rangeStart, rangeEnd = model.rangeEnd }, command )

                Nothing ->
                    ( model, Cmd.none )

        ProfileMode mode ->
            if List.member mode [ "all", "matching", "day" ] then
                ( { model | profileMode = mode }, Cmd.none )

            else
                ( model, Cmd.none )

        ExpandPanel station ->
            ( { model
                | expandedPanels =
                    if Set.member station model.expandedPanels then
                        Set.remove station model.expandedPanels

                    else
                        Set.insert station model.expandedPanels
              }
            , Cmd.none
            )

        Load ->
            case ( model.session, Weather.dayBounds model.dateInput ) of
                ( SignedIn token, Ok ( start, end ) ) ->
                    if Set.isEmpty model.selected then
                        ( { model | feedback = "Bitte wähle mindestens eine Station." }, Cmd.none )

                    else
                        let
                            generation =
                                model.generation + 1

                            selected =
                                Set.toList model.selected

                            inRange =
                                Range.bounds model.range |> Maybe.map (\( first, last ) -> model.dateInput >= first && model.dateInput <= last) |> Maybe.withDefault True

                            nextRange =
                                if inRange then
                                    model.range

                                else
                                    Range.reset model.range
                        in
                        ( { model
                            | generation = generation
                            , stationRevision = model.stationRevision + 1
                            , requestDay = Just model.dateInput
                            , results = Dict.fromList (List.map (\stationId -> ( stationId, DailyCache.get stationId model.dateInput model.dayCache |> Maybe.map Ready |> Maybe.withDefault Pending )) selected)
                            , feedback =
                                if inRange then
                                    ""

                                else
                                    "Zeitraumwahl aufgehoben: Der Detailtag liegt außerhalb."
                            , range = nextRange
                            , rangeStart =
                                if inRange then
                                    model.rangeStart

                                else
                                    model.dateInput
                            , rangeEnd =
                                if inRange then
                                    model.rangeEnd

                                else
                                    model.dateInput
                          }
                        , Cmd.batch
                            (List.filterMap
                                (\stationId ->
                                    if DailyCache.get stationId model.dateInput model.dayCache == Nothing then
                                        Just (Api.measurements model.apiBase token stationId start end (GotMeasurements generation stationId model.dateInput))

                                    else
                                        Nothing
                                )
                                selected
                            )
                        )

                ( _, Err problem ) ->
                    ( { model | feedback = problem }, Cmd.none )

                _ ->
                    ( { model | feedback = "Bitte melde dich zuerst an." }, Cmd.none )

        GotMeasurements generation stationId day result ->
            if generation /= model.generation then
                ( model, Cmd.none )

            else
                let
                    series =
                        case result of
                            Ok rows ->
                                case Weather.validate stationId day rows of
                                    Ok validRows ->
                                        Ready validRows

                                    Err problem ->
                                        Failed problem

                            Err error ->
                                Failed (httpError error)
                in
                ( { model
                    | results = Dict.insert stationId series model.results
                    , dayCache =
                        case series of
                            Ready rows ->
                                DailyCache.remember stationId day rows model.dayCache

                            _ ->
                                model.dayCache
                  }
                , Cmd.none
                )

        LoadYear ->
            if not (isSignedIn model.session) || not (Dict.isEmpty model.yearActive) then
                ( model, Cmd.none )

            else
                let
                    jobs =
                        List.concatMap (\month -> List.map (\station -> YearJob station.id month) Weather.stations) (List.range 1 12)
                            |> List.filter (\job -> not (Set.member ( job.stationId, job.month ) model.yearDone))
                in
                pumpYear { model | yearQueue = jobs, yearErrors = Dict.empty, yearGeneration = model.yearGeneration + 1, yearStarted = True }

        GotYearPage generation stationId month offset result ->
            case Dict.get ( stationId, month ) model.yearActive of
                Nothing ->
                    ( model, Cmd.none )

                Just buffer ->
                    if generation /= model.yearGeneration || offset /= List.length buffer.rows then
                        ( model, Cmd.none )

                    else
                        case result of
                            Err problem ->
                                finishYearMonth stationId month (Err (httpError problem)) model

                            Ok rows ->
                                let
                                    combined =
                                        buffer.rows ++ rows

                                    expected =
                                        List.length (Year.datesInMonth month) * 144
                                in
                                if List.length combined > expected then
                                    finishYearMonth stationId month (Err "Die Monatsantwort enthält mehr Zeilen als das Zehn-Minuten-Raster erlaubt.") model

                                else if List.isEmpty rows || List.length combined == expected then
                                    finishYearMonth stationId month (Year.aggregateMonth stationId month combined) model

                                else if buffer.pages >= 11 then
                                    finishYearMonth stationId month (Err "Die Monatsantwort wurde nach zwölf Seiten abgebrochen. Bitte erneut versuchen.") model

                                else
                                    case model.session of
                                        SignedIn token ->
                                            ( { model | yearActive = Dict.insert ( stationId, month ) { rows = combined, pages = buffer.pages + 1 } model.yearActive }
                                            , Api.monthPage model.apiBase token stationId month (List.length combined) (GotYearPage generation stationId month (List.length combined))
                                            )

                                        _ ->
                                            ( model, Cmd.none )

        ChooseYearDay stationId date ->
            update Load { model | dateInput = date, yearFocus = Year.indexOf date, selected = Set.insert stationId model.selected }

        FocusYearDay stationId index ->
            ( { model | yearFocus = index }
            , Browser.Dom.focus ("year-" ++ String.fromInt stationId ++ "-" ++ String.fromInt index) |> Task.attempt FocusFinished
            )

        FocusFinished _ ->
            ( model, Cmd.none )

        LoadProfiles ->
            case model.session of
                SignedIn token ->
                    if Set.size model.yearDone /= 48 then
                        ( model, Cmd.none )

                    else
                        let
                            ( profiles, command ) =
                                Profiles.load model.apiBase token model.profiles
                        in
                        ( { model | profiles = profiles }, Cmd.map ProfileMessage command )

                _ ->
                    ( model, Cmd.none )

        ProfileMessage message ->
            case model.session of
                SignedIn token ->
                    let
                        ( profiles, command ) =
                            Profiles.update model.apiBase token message model.profiles
                    in
                    ( { model | profiles = profiles }, Cmd.map ProfileMessage command )

                _ ->
                    ( model, Cmd.none )

        ProfileFilter index isLower inputValue ->
            case ( List.drop index ProfileView.axes |> List.head, String.toFloat inputValue ) of
                ( Just axis, Just number ) ->
                    let
                        bounded =
                            clamp axis.lower axis.upper number

                        ( low, high ) =
                            Dict.get index model.filters |> Maybe.withDefault ( axis.lower, axis.upper )

                        bounds =
                            if isLower then
                                ( bounded, max bounded high )

                            else
                                ( min low bounded, bounded )

                        filters =
                            if bounds == ( axis.lower, axis.upper ) then
                                Dict.remove index model.filters

                            else
                                Dict.insert index bounds model.filters
                    in
                    ( { model | filters = filters }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        ResetFilters ->
            ( { model | filters = Dict.empty, profileQuery = "", profileMode = "all" }, Cmd.none )

        ProfileQuery query ->
            ( { model | profileQuery = query }, Cmd.none )

        RangeStart date ->
            ( { model | rangeStart = date }, Cmd.none )

        RangeEnd date ->
            ( { model | rangeEnd = date }, Cmd.none )

        ApplyRange ->
            case ( model.session, Range.datesBetween model.rangeStart model.rangeEnd ) of
                ( SignedIn token, Ok dates ) ->
                    if List.length dates > 7 && Set.size model.yearDone /= 48 then
                        ( { model | feedback = "Ab acht Tagen werden Tagesmittel gezeigt. Bitte zuerst die Jahresdaten laden." }, Cmd.none )

                    else
                        case Range.load model.apiBase token model.rangeStart model.rangeEnd (Set.toList model.selected) model.range of
                            Err problem ->
                                ( { model | feedback = problem }, Cmd.none )

                            Ok ( range, command ) ->
                                let
                                    ( next, dayCommand ) =
                                        update Load { model | range = range, dateInput = model.rangeStart, yearFocus = Year.indexOf model.rangeStart }
                                in
                                ( next, Cmd.batch [ Cmd.map RangeMessage command, dayCommand ] )

                ( _, Err problem ) ->
                    ( { model | feedback = problem }, Cmd.none )

                _ ->
                    ( { model | feedback = "Bitte zuerst anmelden." }, Cmd.none )

        RangeMessage message ->
            case model.session of
                SignedIn token ->
                    let
                        ( range, command ) =
                            Range.update model.apiBase token message model.range
                    in
                    ( { model | range = range }, Cmd.map RangeMessage command )

                _ ->
                    ( model, Cmd.none )

        DifferenceMode enabled ->
            update Load
                { model
                    | difference = enabled
                    , selected =
                        if enabled then
                            Set.fromList [ model.stationA, model.stationB ]

                        else
                            Set.fromList (List.map .id Weather.stations)
                    , range = Range.reset model.range
                }

        PairChanged first inputValue ->
            case String.toInt inputValue of
                Just stationId ->
                    let
                        a =
                            if first then
                                stationId

                            else
                                model.stationA

                        b =
                            if first then
                                model.stationB

                            else
                                stationId
                    in
                    if a == b then
                        ( { model | feedback = "Bitte zwei unterschiedliche Vergleichsstationen wählen." }, Cmd.none )

                    else if model.difference then
                        update Load { model | stationA = a, stationB = b, selected = Set.fromList [ a, b ], range = Range.reset model.range }

                    else
                        ( { model | stationA = a, stationB = b }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ResetSelection ->
            update Load { model | range = Range.reset model.range, rangeStart = "2024-07-15", rangeEnd = "2024-07-15", dateInput = "2024-07-15", yearFocus = Year.indexOf "2024-07-15", filters = Dict.empty, profileQuery = "", profileMode = "all", expandedPanels = Set.empty, difference = False, stationA = 5629, stationB = 722, selected = Set.fromList (List.map .id Weather.stations) }


resetYear : Model -> Model
resetYear model =
    { model | yearDays = Dict.empty, yearDone = Set.empty, yearErrors = Dict.empty, yearActive = Dict.empty, yearQueue = [], yearGeneration = model.yearGeneration + 1, yearStarted = False, profiles = Profiles.reset model.profiles, filters = Dict.empty, profileQuery = "", profileMode = "all", expandedPanels = Set.empty, dayCache = DailyCache.empty, stationRevision = model.stationRevision + 1, range = Range.clearCache (Range.reset model.range), difference = False }


profileMatches : Model -> Maybe (Set ( Int, String ))
profileMatches model =
    if Dict.isEmpty model.filters then
        Nothing

    else
        ProfileView.points model.yearDays model.profiles
            |> List.filter (ProfileView.matches model.filters)
            |> List.map (\point -> ( point.stationId, point.date ))
            |> Set.fromList
            |> Just


pumpYear : Model -> ( Model, Cmd Msg )
pumpYear model =
    case model.session of
        SignedIn token ->
            let
                jobs =
                    List.take (2 - Dict.size model.yearActive) model.yearQueue

                active =
                    List.foldl (\job -> Dict.insert ( job.stationId, job.month ) { rows = [], pages = 0 }) model.yearActive jobs
            in
            ( { model | yearActive = active, yearQueue = List.drop (List.length jobs) model.yearQueue }
            , Cmd.batch (List.map (\job -> Api.monthPage model.apiBase token job.stationId job.month 0 (GotYearPage model.yearGeneration job.stationId job.month 0)) jobs)
            )

        _ ->
            ( model, Cmd.none )


finishYearMonth : Int -> Int -> Result String (Dict String Year.Daily) -> Model -> ( Model, Cmd Msg )
finishYearMonth stationId month result model =
    let
        next =
            { model | yearActive = Dict.remove ( stationId, month ) model.yearActive }
    in
    case result of
        Err problem ->
            pumpYear { next | yearErrors = Dict.insert ( stationId, month ) problem next.yearErrors }

        Ok days ->
            pumpYear
                { next
                    | yearDays = Dict.update stationId (\previous -> Just (Dict.union days (Maybe.withDefault Dict.empty previous))) next.yearDays
                    , yearDone = Set.insert ( stationId, month ) next.yearDone
                }


view : Model -> Html Msg
view model =
    main_ [ class "page" ]
        [ div [ class "heading" ]
            [ p [ class "eyebrow" ] [ text "INFORMATIONSVISUALISIERUNG · DWD" ]
            , h1 [] [ text "Regionale Wetterunterschiede" ]
            , p [ class "intro" ] [ text "Entdecke Temperaturunterschiede im Jahr 2024 und untersuche einzelne Tage im Detail." ]
            , p [ class "milestone" ] [ text "Jahresübersicht, Temperaturvergleich und Wetterprofile sind durch Tageswahl und Profilfilter verbunden." ]
            ]
        , viewAuth model
        , form [ class "card controls", onSubmit ForceLoad ]
            [ h2 [] [ text "Tag und Stationen auswählen" ]
            , div [ class "stations" ]
                (List.map
                    (viewStation model.selected
                        (if model.difference then
                            Set.fromList [ model.stationA, model.stationB ]

                         else
                            Set.empty
                        )
                    )
                    Weather.stations
                )
            , div [ class "row" ]
                [ label [ class "field" ]
                    [ span [] [ text "Tag (UTC)" ]
                    , input [ id "day", type_ "date", Html.Attributes.min "2024-01-01", Html.Attributes.max "2024-12-31", value model.dateInput, onInput DateChanged, required True ] []
                    ]
                , button [ id "load-data", type_ "submit", disabled (not (isSignedIn model.session)) ] [ text "Temperaturen laden" ]
                ]
            , p [ class "help" ] [ text "Stationswechsel aktualisieren die Ansichten automatisch für den geladenen Tag und Zeitraum. Eine neue Datumseingabe wird mit „Temperaturen laden“ übernommen. UTC entspricht im Sommer deutscher Ortszeit minus zwei Stunden." ]
            , p [ class "feedback", attribute "role" "status" ] [ text model.feedback ]
            , div [ class "row" ]
                [ label [] [ text "Zeitraum von", input [ id "range-start", type_ "date", value model.rangeStart, Html.Attributes.min "2024-01-01", Html.Attributes.max "2024-12-31", onInput RangeStart ] [] ]
                , label [] [ text "bis", input [ id "range-end", type_ "date", value model.rangeEnd, Html.Attributes.min "2024-01-01", Html.Attributes.max "2024-12-31", onInput RangeEnd ] [] ]
                , button [ id "apply-range", type_ "button", onClick ApplyRange, disabled (not (isSignedIn model.session)) ] [ text "Zeitraum übernehmen" ]
                ]
            , p [ class "help" ] [ text "Bis sieben Tage: Zehn-Minuten-Werte. Ab acht Tagen: vollständige Tagesmittel aus dem Jahresabruf. Die übernommene Zeitraumwahl markiert die Jahresübersicht und grenzt Wetterprofile ein." ]
            , div [ class "row" ]
                [ label [] [ input [ id "difference-mode", type_ "checkbox", Html.Attributes.checked model.difference, onCheck DifferenceMode, disabled (not (isSignedIn model.session)) ] [], text "Temperaturdifferenz A minus B" ]
                , pairSelector model True
                , pairSelector model False
                , button [ id "reload-range", type_ "button", onClick ForceRange, disabled (Range.bounds model.range == Nothing) ] [ text "Zeitraum neu abrufen" ]
                , button [ id "reset-selection", type_ "button", onClick ResetSelection, disabled (not (isSignedIn model.session)) ] [ text "Auswahl zurücksetzen" ]
                ]
            , p [ class "help" ] [ text "Im Differenzmodus bleiben A und B für den Vergleich aktiv. Modus- und Paarwechsel heben eine übernommene Zeitraumwahl auf. Ein Detailtag außerhalb des Zeitraums hebt ebenfalls die Zeitraumwahl auf. „Auswahl zurücksetzen“ stellt alle Stationen und den 15. Juli wieder her und entfernt Zeitraum- und Profilfilter; geladene Jahresdaten bleiben erhalten." ]
            ]
        , YearView.view
            { days =
                if model.difference then
                    Dict.singleton 0 (Difference.days model.stationA model.stationB model.yearDays)

                else
                    model.yearDays
            , done = model.yearDone
            , errors =
                if model.difference then
                    Difference.monthErrors model.stationA model.stationB model.yearErrors

                else
                    model.yearErrors
            , active = Dict.size model.yearActive
            , queued = List.length model.yearQueue
            , started = model.yearStarted
            , signedIn = isSignedIn model.session
            , selected =
                if model.difference then
                    Set.singleton 0

                else
                    model.selected
            , selectedDay = model.requestDay
            , focusIndex = model.yearFocus
            , load = LoadYear
            , choose =
                if model.difference then
                    \_ date -> ChooseYearDay model.stationA date

                else
                    ChooseYearDay
            , expanded = model.expandedPanels
            , expand = ExpandPanel
            , focus = FocusYearDay
            , matching =
                if model.difference then
                    Difference.matching model.stationA model.stationB (profileMatches model)

                else
                    profileMatches model
            , difference = model.difference
            , stations =
                if model.difference then
                    [ Weather.Station 0 (Difference.name model.stationA ++ " minus " ++ Difference.name model.stationB ++ " (A − B)") "#526d79" ]

                else
                    Weather.stations
            , range = Range.bounds model.range
            }
        , RangeView.view { range = model.range, days = model.yearDays, matching = profileMatches model }
        , ProfileView.view
            { model = model.profiles
            , yearDays = model.yearDays
            , selected = model.selected
            , day = model.requestDay
            , filters = model.filters
            , canLoad = isSignedIn model.session && Set.size model.yearDone == 48
            , query = model.profileQuery
            , search = ProfileQuery
            , mode = model.profileMode
            , display = ProfileMode
            , load = LoadProfiles
            , filter = ProfileFilter
            , reset = ResetFilters
            , choose = ChooseYearDay
            , range = Range.bounds model.range
            }
        , viewResults model
        , p [ class "footer" ] [ text "Quelle: Deutscher Wetterdienst, bereitgestellt über die Universität Halle. Zehn-Minuten-Momentanwerte in 2 m Höhe; fehlende Werte bleiben fehlend." ]
        ]


isSignedIn : Session -> Bool
isSignedIn session =
    case session of
        SignedIn _ ->
            True

        _ ->
            False


viewAuth : Model -> Html Msg
viewAuth model =
    if isSignedIn model.session then
        div [ class "card auth connected" ]
            [ div [] [ h2 [] [ text "Mit Datenserver verbunden" ], p [ class "help" ] [ text "Der Zugang gilt für diese Sitzung. Beim Neuladen ist eine neue Anmeldung erforderlich." ] ]
            , button [ type_ "button", onClick Logout, class "secondary" ] [ text "Abmelden" ]
            ]

    else
        form [ class "card auth", onSubmit Login ]
            [ h2 [] [ text "Veranstaltungszugang" ]
            , p [ class "help" ] [ text "Verwende den Zugang aus den Stud.IP-Unterlagen. Zugangsdaten werden nicht dauerhaft gespeichert." ]
            , div [ class "row" ]
                [ label [ class "field" ] [ span [] [ text "Benutzername" ], input [ id "username", name "username", attribute "autocomplete" "username", value model.username, onInput UsernameChanged, required True ] [] ]
                , label [ class "field" ] [ span [] [ text "Passwort" ], input [ id "password", name "password", type_ "password", attribute "autocomplete" "current-password", value model.password, onInput PasswordChanged, required True ] [] ]
                , button [ id "login", type_ "submit", disabled (model.session == LoggingIn) ]
                    [ text
                        (if model.session == LoggingIn then
                            "Verbindung wird hergestellt …"

                         else
                            "Verbinden"
                        )
                    ]
                ]
            , p [ class "feedback", attribute "role" "status" ]
                [ text
                    (case model.session of
                        AuthError problem ->
                            problem

                        _ ->
                            ""
                    )
                ]
            ]


viewStation : Set Int -> Set Int -> Station -> Html Msg
viewStation selected protected station =
    label [ class "station" ]
        [ input [ type_ "checkbox", attribute "data-station" (String.fromInt station.id), Html.Attributes.checked (Set.member station.id selected), disabled (Set.member station.id protected), onCheck (StationChanged station.id) ] []
        , span [ class "swatch", style "background" station.color ] []
        , text station.name
        ]


pairSelector : Model -> Bool -> Html Msg
pairSelector model first =
    let
        other =
            if first then
                model.stationB

            else
                model.stationA

        chosen =
            if first then
                model.stationA

            else
                model.stationB
    in
    label []
        [ text
            (if first then
                "A"

             else
                "B"
            )
        , Html.select
            [ id
                (if first then
                    "station-a"

                 else
                    "station-b"
                )
            , value (String.fromInt chosen)
            , onInput (PairChanged first)
            ]
            (List.map (\station -> Html.option [ value (String.fromInt station.id), Html.Attributes.selected (station.id == chosen), disabled (station.id == other) ] [ text station.name ]) Weather.stations)
        ]


readySeries : Dict Int Series -> List ( Station, List Measurement )
readySeries results =
    List.filterMap
        (\station ->
            case Dict.get station.id results of
                Just (Ready rows) ->
                    Just ( station, rows )

                _ ->
                    Nothing
        )
        Weather.stations


viewResults : Model -> Html Msg
viewResults model =
    case model.requestDay of
        Nothing ->
            div [ class "card empty", id "day-results" ] [ h2 [] [ text "Temperaturvergleich" ], p [] [ text "Nach der Anmeldung laden wir den 15. Juli 2024 als ersten Vergleichstag." ] ]

        Just day ->
            let
                ready =
                    readySeries model.results
            in
            div [ class "card results", id "day-results" ]
                [ h2 [] [ text ("Temperaturen am " ++ day ++ " · UTC") ]
                , p [ class "help", attribute "role" "status" ]
                    [ text
                        (if List.any ((==) Pending) (Dict.values model.results) then
                            "Messwerte werden geladen … Bereits geladene Stationen sind sichtbar."

                         else
                            "Abruf abgeschlossen · Zehn-Minuten-Werte · gemeinsame Temperaturskala"
                        )
                    ]
                , div [ class "chart" ] [ viewChart (profileMatches model) model.requestDay ready ]
                , if Dict.isEmpty model.filters then
                    text ""

                  else
                    p [ class "help" ] [ text "Aktive Profilfilter: abgeblendete Stationen erfüllen am gewählten Tag kein passendes vollständiges Wetterprofil. Ihre verfügbaren Temperaturwerte bleiben als Kontext sichtbar." ]
                , table []
                    [ thead [] [ tr [] (List.map (\title -> th [] [ text title ]) [ "Station", "Messabdeckung", "Temperaturmittel", "Status" ]) ]
                    , tbody [] (List.filterMap (viewSummary model.results) Weather.stations)
                    ]
                , p [ class "help" ] [ text "Tagesmittel nur bei 144 vorhandenen Temperaturwerten. Bei Fehlstellen stehen vorhandene Einzelwerte weiter zur Verfügung; Linien überbrücken die Lücken nicht." ]
                , viewDetails ready
                ]


validTemperatures : List Measurement -> List Float
validTemperatures rows =
    List.filterMap
        (\row ->
            if row.quality == 0 then
                Nothing

            else
                row.temperature
        )
        rows


format : Float -> String
format number =
    String.replace "." "," (String.fromFloat (toFloat (round (number * 100)) / 100))


viewSummary : Dict Int Series -> Station -> Maybe (Html Msg)
viewSummary results station =
    Dict.get station.id results
        |> Maybe.map
            (\series ->
                let
                    ( coverage, mean, status ) =
                        case series of
                            Pending ->
                                ( "–", "–", "Lädt …" )

                            Failed problem ->
                                ( "–", "–", problem )

                            Ready rows ->
                                let
                                    values =
                                        validTemperatures rows

                                    count =
                                        List.length values

                                    qualityWarning =
                                        List.any (\row -> row.quality /= 3) rows
                                in
                                ( String.fromInt count ++ " / 144"
                                , if count == 144 && not qualityWarning then
                                    format (List.sum values / 144) ++ " °C"

                                  else
                                    "Nicht verfügbar"
                                , if List.isEmpty rows then
                                    "Keine Datensätze für diesen Tag"

                                  else if qualityWarning then
                                    "Abweichende Qualitätsklasse: Tagesmittel zurückgestellt"

                                  else if count == 144 then
                                    "Vollständig"

                                  else if count == 0 then
                                    "Keine Temperaturwerte vorhanden"

                                  else
                                    "Unvollständig: Rohwerte verfügbar"
                                )
                in
                tr [ attribute "data-summary" (String.fromInt station.id) ]
                    [ td [] [ span [ class "swatch", style "background" station.color ] [], text station.name ]
                    , td [] [ text coverage ]
                    , td [] [ text mean ]
                    , td [] [ text status ]
                    ]
            )


segments : List Measurement -> List (List Measurement)
segments rows =
    let
        step row ( current, finished ) =
            if row.temperature == Nothing || row.quality == 0 then
                ( []
                , if List.isEmpty current then
                    finished

                  else
                    List.reverse current :: finished
                )

            else
                case current of
                    previous :: _ ->
                        if Weather.minuteOfDay row - Weather.minuteOfDay previous == 10 then
                            ( row :: current, finished )

                        else
                            ( [ row ], List.reverse current :: finished )

                    [] ->
                        ( [ row ], finished )

        ( last, complete ) =
            List.foldl step ( [], [] ) rows
    in
    List.reverse
        (if List.isEmpty last then
            complete

         else
            List.reverse last :: complete
        )


viewChart : Maybe (Set ( Int, String )) -> Maybe String -> List ( Station, List Measurement ) -> Html Msg
viewChart matching day series =
    let
        values =
            List.concatMap (Tuple.second >> validTemperatures) series

        lower =
            toFloat (floor (Maybe.withDefault 0 (List.minimum values) / 5)) * 5 - 2

        upper =
            toFloat (ceiling (Maybe.withDefault 25 (List.maximum values) / 5)) * 5 + 2

        x minute =
            65 + toFloat minute / 1440 * 895

        y temperature =
            260 - (temperature - lower) / (upper - lower) * 220

        point row =
            String.fromFloat (x (Weather.minuteOfDay row)) ++ "," ++ String.fromFloat (y (Maybe.withDefault lower row.temperature))

        tick number =
            let
                temperature =
                    lower + toFloat number / 4 * (upper - lower)
            in
            Svg.g []
                [ Svg.line [ SA.x1 "65", SA.x2 "960", SA.y1 (String.fromFloat (y temperature)), SA.y2 (String.fromFloat (y temperature)), SA.stroke "#e2e8ee" ] []
                , Svg.text_ [ SA.x "53", SA.y (String.fromFloat (y temperature + 4)), SA.textAnchor "end", SA.fontSize "18" ] [ Svg.text (format temperature) ]
                ]

        hourTick hour =
            Svg.text_ [ SA.x (String.fromFloat (x (hour * 60))), SA.y "283", SA.textAnchor "middle", SA.fontSize "18" ] [ Svg.text (String.padLeft 2 '0' (String.fromInt hour) ++ ":00") ]

        draw ( station, rows ) =
            Svg.g
                [ attribute "data-series" (String.fromInt station.id)
                , attribute "data-profile-match"
                    (matching
                        |> Maybe.map
                            (\selected ->
                                if Set.member ( station.id, Maybe.withDefault "" day ) selected then
                                    "true"

                                else
                                    "false"
                            )
                        |> Maybe.withDefault "none"
                    )
                , SA.opacity
                    (matching
                        |> Maybe.map
                            (\selected ->
                                if Set.member ( station.id, Maybe.withDefault "" day ) selected then
                                    "1"

                                else
                                    "0.15"
                            )
                        |> Maybe.withDefault "1"
                    )
                ]
                (List.concatMap
                    (\part ->
                        case part of
                            [ row ] ->
                                [ Svg.circle [ SA.cx (String.fromFloat (x (Weather.minuteOfDay row))), SA.cy (String.fromFloat (y (Maybe.withDefault lower row.temperature))), SA.r "3", SA.fill station.color ] [] ]

                            _ ->
                                [ Svg.polyline [ SA.points (String.join " " (List.map point part)), SA.fill "none", SA.stroke station.color, SA.strokeWidth "2", SA.strokeLinecap "round", SA.strokeLinejoin "round" ] [] ]
                    )
                    (segments rows)
                )
    in
    if List.isEmpty values then
        p [ class "empty-chart" ] [ text "Für die geladenen Stationen sind keine darstellbaren Temperaturwerte vorhanden." ]

    else
        Svg.svg [ SA.viewBox "0 0 1000 310", attribute "role" "img", attribute "aria-label" "Temperaturverläufe der geladenen Stationen mit gemeinsamer UTC-Zeitachse" ]
            ([ Svg.text_ [ SA.x "18", SA.y "25", SA.fontSize "18" ] [ Svg.text "°C" ] ]
                ++ List.map tick (List.range 0 4)
                ++ List.map hourTick [ 0, 6, 12, 18, 24 ]
                ++ List.map draw series
                ++ [ Svg.text_ [ SA.x "510", SA.y "306", SA.textAnchor "middle", SA.fontSize "18" ] [ Svg.text "Uhrzeit (UTC)" ] ]
            )


viewDetails : List ( Station, List Measurement ) -> Html Msg
viewDetails series =
    Html.details []
        [ Html.summary [] [ text "Geladene Einzelwerte und Qualitätskennzeichen ansehen" ]
        , div [ class "raw-table" ]
            [ table []
                [ thead [] [ tr [] (List.map (\title -> th [] [ text title ]) [ "Station", "Zeit (UTC)", "Temperatur °C", "Feuchtigkeit %", "Qualitätsklasse" ]) ]
                , tbody []
                    (List.concatMap
                        (\( station, rows ) ->
                            List.map
                                (\row -> tr [] [ td [] [ text station.name ], td [] [ text (String.slice 11 16 row.timestamp) ], td [] [ text (Maybe.map format row.temperature |> Maybe.withDefault "Fehlend") ], td [] [ text (Maybe.map format row.humidity |> Maybe.withDefault "Fehlend") ], td [] [ text (String.fromInt row.quality) ] ])
                                rows
                        )
                        series
                    )
                ]
            ]
        ]
