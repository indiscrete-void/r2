# pnet (Pandora Network)
## Overview of pnet architecture
```
                                x----------------------------------------x  
                                |                                        |  
               ┌───────────┐ ┌────┐    ┌────┐  ┌────────────┐            |  
          ┌────┤pnet tunnel├─┤proc│ ┌──┤proc├──┤pnet connect├────┐       |  
          │    └───────────┘ └────┘ │  └────┘  └────────────┘    │       |  
┌────┐ ┌──┴──┐                      │                         ┌──┴──┐ ┌────┐
│proc├─┤pnetd│                      └─┐                       │pnetd├─┤proc│
└────┘ └──┬──┘                        │                       └──┬──┘ └────┘
   |      │    ┌────────────┐  ┌────┐ │  ┌────┐ ┌───────────┐    │          
   |      └────┤pnet connect├──┤proc├─┘  │proc├─┤pnet tunnel├────┘          
   |           └────────────┘  └────┘    └────┘ └───────────┘               
   |                                        !                               
   x----------------------------------------x                                                      
```

The daemon (pnetd) implements:
- Custom recursive routing protocol called ipchains which is used for both node-to-node and manager-to-node communication (which could actually be simplified to just node-to-node since manager is a node too)
- In-memory node database
- Daemon-Manager communication protocol

The manager (pnet) provides transport for daemons via `pnet-connect` and transport for application layer programs via `pnet-tunnel`, with both subcommands sharing the same interface.

pnetd and pnet communicate via UNIX socket at /var/run/pnet (or custom path defined by $PNET_SOCKET_PATH)

## Examples
```sh
# run daemon with ioshd posing as tunnel process
pnetd ioshd

# connect to ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 via "socat tcp:example.com:47210 -"
pnet connect ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 "socat tcp:example.com:47210 -"

# introduce ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 to the network when it's connection is accepted by `socat tcp-l:47210`
socat tcp-l:47210 exec:"pnet connect ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 -"

# replace TCP/IP on eth0 with pnet protocol and communicate with ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 on other end
pnet connect ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 "socat interface:eth0 -"

# connect to ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 via bluetooth socket on channel 3
pnet connect ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 "rfcomm connect /dev/rfcomm0 00:B0:D0:63:C2:26 3"

# connect iosh to ioshd provided as the tunnel process of ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3
iosh -t "pnet tunnel ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 -" zsh -l

# create pnet0 network interface connected to ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3
pnet tunnel ffd8e654b8271c489b2d4cd236c327d4f4091f0958b31af8d6d893905a1ef6c3 "socat tun,iff-up,device-name=pnet0 -"
```

Note that in actual implementation public keys will get shorter for better experience
