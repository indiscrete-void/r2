module Main

import PubSub
import Device
import WebSocket
import ConnTab
import Router
import Addr
import JSON
import Linking

main : IO ()
main = do
    ws <- WS.new
    connTab <- ConnTab.new
    router <- Router.new

    linkWSAndConnTab ws connTab.device
    linkConnTabAndRouterJSON RouterMsgEncoding.json connTab.device router

    Device.sub router $ \case
        Router.Recv addr msg => do
            putStrLn $ show addr ++ " router recv " ++ msg
            case msg of
                "hello" => exec router (Send addr "hello")
                _ => pure ()
        Router.Error addr err => putStrLn $ show addr ++ " router err " ++ err

    exec ws (Open "ws://localhost:1337")
