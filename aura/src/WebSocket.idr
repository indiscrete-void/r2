module WebSocket

import Device
import PubSub
import Data.IORef

%foreign "javascript:lambda:(url) => new WebSocket(url)"
prim__wsNew : String -> PrimIO AnyPtr

%foreign "javascript:lambda:(sock,callback) => sock.addEventListener('open', () => callback())"
prim__wsSubOpen : AnyPtr -> PrimIO () -> PrimIO ()

%foreign "javascript:lambda:(sock,callback) => sock.addEventListener('message', x => callback(x.data)())"
prim__wsSubMsg : AnyPtr -> (String -> PrimIO ()) -> PrimIO ()

%foreign "javascript:lambda:(sock,str) => sock.send(str)"
prim__wsSend : AnyPtr -> String -> PrimIO ()

%foreign "javascript:lambda:(sock) => sock.close()"
prim__wsClose : AnyPtr -> PrimIO ()

public export
record WebSocket where
    constructor MkWebSocket
    url : String
    ptr : AnyPtr

wsNew : HasIO io => String -> io WebSocket
wsNew url = MkWebSocket url <$> primIO (prim__wsNew url)

wsSubOpen : HasIO io => WebSocket -> IO () -> io ()
wsSubOpen (MkWebSocket _ sock) callback =
  primIO $ prim__wsSubOpen sock $ toPrim callback

wsSubMsg : HasIO io => WebSocket -> (String -> IO ()) -> io ()
wsSubMsg (MkWebSocket _ sock) callback =
  primIO $ prim__wsSubMsg sock (\ptr => toPrim $ callback ptr)

wsSend : HasIO io => WebSocket -> String -> io ()
wsSend (MkWebSocket _ sock) str = primIO $ prim__wsSend sock str

wsClose : HasIO io => WebSocket -> io ()
wsClose (MkWebSocket _ sock) = primIO $ prim__wsClose sock

namespace WS
    public export
    data Cmd = Open String | Send WebSocket String | Close WebSocket

    public export
    data Event = Opened WebSocket | Recv WebSocket String | Closed WebSocket

    public export
    Device : (m : Type -> Type) -> Type
    Device m = (Device.Device m WS.Event WS.Cmd)

    exec : IORef (PubSub IO Event) -> Cmd -> IO ()
    exec events (Open url) = wsNew url >>= \sock => do
        wsSubMsg sock $ \str => pubIORef events (Recv sock str)
        wsSubOpen sock $ pubIORef events (Opened sock)
    exec events (Send sock a) = wsSend sock a
    exec events (Close sock) = wsClose sock >> pubIORef events (Closed sock)

    export
    new : IO (WS.Device IO)
    new = do
        eventsRef <- newIORef emptyPubSub
        pure $ MkDevice eventsRef (WS.exec eventsRef)
