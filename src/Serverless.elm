module Serverless
    exposing
        ( httpApi
        , Flags
        , HttpApi
        , Program
        , RequestPort
        , ResponsePort
        )

{-| __Experimental (WIP): Not for use in production__

Define an HTTP API in elm.

@docs httpApi, Flags, HttpApi, Program, RequestPort, ResponsePort
-}

import Json.Decode exposing (Decoder, decodeValue)
import Json.Encode as J
import Serverless.Conn.Pool as Pool exposing (..)
import Serverless.Conn.Private exposing (..)
import Serverless.Conn.Types exposing (..)
import Serverless.Plug exposing (..)
import Serverless.Plug.Private exposing (..)


{-| Create an program for handling HTTP connections.
-}
httpApi :
    HttpApi config model msg
    -> Program config model msg
httpApi program =
    Platform.programWithFlags
        { init = init_ program
        , update = update_ program
        , subscriptions = sub_ program
        }


{-| Serverless program type
-}
type alias Program config model msg =
    Platform.Program Flags (Model config model msg) (Msg msg)


{-| Type of flags for program
-}
type alias Flags =
    J.Value


{-| Program for an HTTP API.

A Serverless.Program is parameterized by your 3 custom types

* Config is a server load-time record of deployment specific values
* Model is for whatever you need during the processing of a request
* Msg is your app message type

You must provide the following:

* `configDecoder` decodes a JSON value for your custom config type
* `requestPort` and `responsePort` must be defined in your app since an elm library cannot expose ports. They should have types `Serverless.RequestPort` and `Serverless.ResponsePort`, respectively
* `endpoint` is a message through which connections are first received
* `initialModel` is a value to which new connections will set their model
* `pipeline` takes the place of the update function in a traditional elm program
* `subscriptions` has the usual meaning

See the Plug module for more details on pipelines and plugs.
-}
type alias HttpApi config model msg =
    { configDecoder : Decoder config
    , requestPort : RequestPort (Msg msg)
    , responsePort : ResponsePort (Msg msg)
    , endpoint : msg
    , initialModel : model
    , pipeline : Pipeline config model msg
    , subscriptions : Conn config model -> Sub msg
    }


{-| Type of port through which the request is received.
Set your request port to this type.
-}
type alias RequestPort msg =
    (J.Value -> msg) -> Sub msg


{-| Type of port through which the request is sent.
Set your response port to this type.
-}
type alias ResponsePort msg =
    J.Value -> Cmd msg



-- IMPLEMENTATION


type alias Model config model msg =
    { pool : Pool config model
    , pipeline : BakedPipeline config model msg
    }


init_ :
    HttpApi config model msg
    -> Flags
    -> ( Model config model msg, Cmd (Msg msg) )
init_ program flags =
    case decodeValue program.configDecoder flags of
        Ok config ->
            ( (Model
                (Pool.empty program.initialModel (Just config))
                (bakePipeline program.pipeline)
              )
                |> Debug.log "Initialized"
            , Cmd.none
            )

        Err err ->
            (Model
                (Pool.empty program.initialModel Nothing)
                ([] |> bakePipeline)
            )
                |> reportFailure "Initialization failed" err


type Msg msg
    = RawRequest J.Value
    | HandlerMsg Id (PlugMsg msg)


update_ :
    HttpApi config model msg
    -> Msg msg
    -> Model config model msg
    -> ( Model config model msg, Cmd (Msg msg) )
update_ program slsMsg model =
    case slsMsg of
        RawRequest raw ->
            case raw |> decodeValue requestDecoder of
                Ok req ->
                    { model | pool = model.pool |> Pool.add req }
                        |> updateChild program
                            req.id
                            (PlugMsg 0 program.endpoint)

                Err err ->
                    model |> reportFailure "Error decoding request" err

        HandlerMsg requestId msg ->
            updateChild program requestId msg model


updateChild : HttpApi config model msg -> Id -> PlugMsg msg -> Model config model msg -> ( Model config model msg, Cmd (Msg msg) )
updateChild program requestId msg model =
    case model.pool |> Pool.get requestId of
        Just conn ->
            let
                ( newConn, cmd ) =
                    applyPipeline
                        program.endpoint
                        model.pipeline
                        msg
                        []
                        conn
            in
                ( { model | pool = model.pool |> Pool.replace newConn }
                , Cmd.map (HandlerMsg requestId) cmd
                )

        _ ->
            model |> reportFailure "No connection in pool with id: " requestId


sub_ :
    HttpApi config model msg
    -> Model config model msg
    -> Sub (Msg msg)
sub_ program model =
    model.pool
        |> Pool.connections
        |> List.map
            (\conn ->
                program.subscriptions conn
                    |> Sub.map (PlugMsg 0)
                    |> Sub.map (HandlerMsg conn.req.id)
            )
        |> List.append [ program.requestPort RawRequest ]
        |> Sub.batch


reportFailure : String -> value -> Model config model msg -> ( Model config model msg, Cmd (Msg msg) )
reportFailure msg value model =
    let
        _ =
            Debug.log msg value
    in
        ( model, Cmd.none )