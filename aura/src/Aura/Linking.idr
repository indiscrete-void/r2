|||
||| Utilities for connecting devices together
|||
module Aura.Linking

import Aura.ConnTab
import Aura.Router
import Aura.Device
import public Aura.Device.Stateful as Stateful
import Aura.WebSocket
import Aura.Addr
import Aura.PubSub
import JSON

public export
record RouterMsgEncoding a where
    constructor MkRouterMsgEncoding
    encode : Router.Msg a -> a
    decodeOrWrap : a -> Router.Msg a

namespace RouterMsgEncoding
    public export
    json : RouterMsgEncoding String
    json = MkRouterMsgEncoding
        { encode = JSON.ToJSON.encode
        , decodeOrWrap = \str =>
            case decode {a = Router.Msg String} str of
                Left _ => MsgData str
                Right decodedMsg => decodedMsg
        }

public export
linkStateful : (HasIO io, Stateful.Device io a h dev, Show a) => RouterMsgEncoding a -> Router.Device io a -> dev -> io ()
linkStateful encoding router dev =
    Stateful.sub dev $ \case
        Stateful.Opened hndl => do
            let addr = Stateful.handleToAddr dev hndl
            let send = \o => MkSent <$ Stateful.send dev hndl (encoding.encode o)
            putStrLn $ show addr ++ " st opened"
            exec router $ AddRoute addr send
        Stateful.Recv hndl str => do
            let addr = Stateful.handleToAddr dev hndl
            let msg = encoding.decodeOrWrap str
            putStrLn $ show addr ++ " st recv " ++ show msg
            exec router $ Handle addr msg
        Stateful.Closed hndl => do
            let addr = Stateful.handleToAddr dev hndl
            putStrLn $ show addr ++ " st closed"
            exec router $ RemoveRoute addr
