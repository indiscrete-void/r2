module Aura.Main

import Aura.PubSub
import Aura.Device
import Aura.WebSocket
import Aura.ConnTab
import Aura.Router
import Aura.Addr
import Aura.Linking

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
