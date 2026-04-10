module Aura.Main

import Aura.PubSub
import Aura.Device
import Aura.WebSocket
import Aura.Router
import Aura.Addr
import Aura.Linking

main : IO ()
main = do
    ws <- WS.new
    router <- Router.new

    linkStateful RouterMsgEncoding.json router ws

    Device.sub router $ \case
        Router.Recv addr msg => do
            putStrLn $ show addr ++ " router recv " ++ msg
            case msg of
                "hello" => exec router (Send addr "hello")
                _ => pure ()
        Router.Sent addr msg => putStrLn $ show addr ++ " router send " ++ msg
        Router.Error addr err => putStrLn $ show addr ++ " router err " ++ err

    exec ws (Open $ MkURL {scheme = "ws", host = "localhost", port = Just 1337, path = []})
