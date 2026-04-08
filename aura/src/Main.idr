module Main

import PubSub
import Device
import WebSocket
import ConnTab
import Router
import Addr
import JSON

main : IO ()
main = do
    connTab : ConnTab.ConnTab IO String <- ConnTab.new

    ws <- WS.new
    Device.sub ws $ \case
        WS.Opened sock => do
            putStrLn $ url sock ++ " ws opened"
            let lease = ConnTab.MkLease
                            { send = exec ws . WS.Send sock
                            , close = exec ws (WS.Close sock)
                            }
            exec (connTab.antenna) (ConnTab.Open (MkNameAddr $ url sock) lease)
        WS.Recv sock a => do
            putStrLn $ url sock ++ " ws recv " ++ a
            pubIORef (connTab.antenna.events) (ConnTab.Recv (MkNameAddr $ url sock) a)
        WS.Closed sock => do
            putStrLn $ url sock ++ " ws closed"

    let sendToLeaseEncoded : ConnTab.Lease IO String -> SendM IO (Router.Msg String)
        sendToLeaseEncoded lease out = MkSent <$ lease.send (JSON.ToJSON.encode out)

    router : Router.Device IO String <- Router.new
    Device.sub router $ \case
        Router.Recv addr msg => do
            putStrLn $ show addr ++ " router recv " ++ msg
            case msg of
                "hello" => exec router (Send addr "hello")
                _ => pure ()
        Router.Error addr err => putStrLn $ show addr ++ " router err " ++ err

    Device.sub connTab.antenna $ \case
        ConnTab.Opened addr lease => do
            putStrLn $ show addr ++ " conn opened"
            exec router $ AddRoute addr (sendToLeaseEncoded lease)
        ConnTab.Recv addr str => do
            putStrLn $ show addr ++ " conn recv " ++ show str
            let netAddr = MkNetworkNameAddr addr
            let msg = case decode {a = Router.Msg String} str of
                    Left _ => MsgData str
                    Right decodedMsg => decodedMsg
            exec router $ Handle netAddr msg
        ConnTab.Closed addr => do
            putStrLn $ show addr ++ " conn closed"
            exec router $ RemoveRoute addr

    exec ws (Open "ws://localhost:1337")
