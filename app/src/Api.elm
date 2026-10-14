module Api exposing (login, measurements, monthPage)

import Base64
import Http
import Json.Decode as Decode
import Weather exposing (Measurement)
import Year


login : String -> String -> String -> (Result Http.Error String -> msg) -> Cmd msg
login base username password toMessage =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Basic " ++ Base64.encode (username ++ ":" ++ password)) ]
        , url = base ++ "/token"
        , body = Http.emptyBody
        , expect = Http.expectJson toMessage (Decode.field "token" Decode.string)
        , timeout = Just 30000
        , tracker = Nothing
        }


measurements : String -> String -> Int -> String -> String -> (Result Http.Error (List Measurement) -> msg) -> Cmd msg
measurements base token stationId start end toMessage =
    requestMeasurements base token stationId start end 145 0 toMessage


monthPage : String -> String -> Int -> Int -> Int -> (Result Http.Error (List Measurement) -> msg) -> Cmd msg
monthPage base token stationId month offset toMessage =
    let
        ( start, end ) =
            Year.monthBounds month
    in
    requestMeasurements base token stationId start end 5000 offset toMessage


requestMeasurements : String -> String -> Int -> String -> String -> Int -> Int -> (Result Http.Error (List Measurement) -> msg) -> Cmd msg
requestMeasurements base token stationId start end limit offset toMessage =
    Http.request
        { method = "GET"
        , headers =
            [ Http.header "Authorization" ("Bearer " ++ token)
            , Http.header "Accept-Profile" "dwd"
            ]
        , url =
            base
                ++ "/v_air_temperature?station_id=eq."
                ++ String.fromInt stationId
                ++ "&timestamp=gte."
                ++ start
                ++ "&timestamp=lt."
                ++ end
                ++ "&select=station_id,timestamp,lufttemperatur_c,rel_feuchte_prozent,quality_class_id&order=timestamp.asc&limit="
                ++ String.fromInt limit
                ++ "&offset="
                ++ String.fromInt offset
        , body = Http.emptyBody
        , expect = Http.expectJson toMessage Weather.decoder
        , timeout = Just 30000
        , tracker = Nothing
        }
