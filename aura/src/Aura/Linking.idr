|||
||| Utilities for connecting devices together
|||
module Aura.Linking

import Aura.ConnTab
import Aura.Router
import Aura.Device
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
        { encode = JSON.ToJSON.encode,
        decodeOrWrap = \str =>
            case decode {a = Router.Msg String} str of
                Left _ => MsgData str
                Right decodedMsg => decodedMsg
        }

public export
linkConnTabAndRouterJSON : (Show a, HasIO io) => RouterMsgEncoding a -> ConnTab.Device io a -> Router.Device io a -> io ()
linkConnTabAndRouterJSON encoding connTab router =
    Device.sub connTab $ \case
        ConnTab.Opened addr lease => do
            liftIO $ putStrLn $ show addr ++ " conn opened"
            exec router $ AddRoute addr (\o => MkSent <$ lease.send (encoding.encode o))
        ConnTab.Recv addr str => do
            let netAddr = MkNetworkNameAddr addr
            let msg = encoding.decodeOrWrap str
            putStrLn $ show addr ++ " conn recv " ++ show msg
            exec router $ Handle netAddr msg
        ConnTab.Closed addr => do
            putStrLn $ show addr ++ " conn closed"
            exec router $ RemoveRoute addr

public export
linkWSAndConnTab : HasIO io => WS.Device io -> ConnTab.Device io String -> io ()
linkWSAndConnTab ws connTab =
    Device.sub ws $ \case
        WS.Opened sock => do
            putStrLn $ url sock ++ " ws opened"
            let lease = ConnTab.MkLease
                            { send = exec ws . WS.Send sock
                            , close = exec ws (WS.Close sock)
                            }
            exec connTab (ConnTab.Open (MkNameAddr $ url sock) lease)
        WS.Recv sock a => do
            putStrLn $ url sock ++ " ws recv " ++ a
            pubIORef (connTab.events) (ConnTab.Recv (MkNameAddr $ url sock) a)
        WS.Closed sock => do
            putStrLn $ url sock ++ " ws closed"
            exec connTab (ConnTab.Close (MkNameAddr $ url sock))
