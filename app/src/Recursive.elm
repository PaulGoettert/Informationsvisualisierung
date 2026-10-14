module Recursive exposing (Level, positions)


type alias Level =
    { width : Int, height : Int }


{-| Eigener zeilenweiser Koordinatenerzeuger nach dem in der Veranstaltung
bereitgestellten createPixelMap-Verfahren. Die Ebenen stehen außen nach innen.
Quelle und Abgleich: Entwurf/RECURSIVE\_PATTERN\_ABGLEICH.md.
-}
positions : List Level -> List ( Int, Int )
positions levels =
    case levels of
        [] ->
            [ ( 0, 0 ) ]

        level :: children ->
            let
                childWidth =
                    List.product (List.map .width children)

                childHeight =
                    List.product (List.map .height children)

                childPositions =
                    positions children
            in
            List.concatMap
                (\row ->
                    List.concatMap
                        (\column -> List.map (\( x, y ) -> ( column * childWidth + x, row * childHeight + y )) childPositions)
                        (List.range 0 (level.width - 1))
                )
                (List.range 0 (level.height - 1))
