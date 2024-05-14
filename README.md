# pnet (Pandora Network)
## Overview of pnet architecture
```
                               x----------------------------------------x
                               |                                        |
               ┌───────────┐ ┌────┐   ┌────┐  ┌────────────┐            |
          ┌────┤pnet tunnel├─┤proc│ ┌─┤proc├──┤pnet connect├────┐       |
          │    └───────────┘ └────┘ │ └────┘  └────────────┘    │       |
┌────┐ ┌──┴──┐                      │                        ┌──┴──┐ ┌────┐
│proc├─┤pnetd│                      └─┐                      │pnetd├─┤proc│
└────┘ └──┬──┘                        │                      └──┬──┘ └────┘
  |       │    ┌────────────┐  ┌────┐ │ ┌────┐ ┌───────────┐    │
  |       └────┤pnet connect├──┤proc├─┘ │proc├─┤pnet tunnel├────┘
  |            └────────────┘  └────┘   └────┘ └───────────┘
  |                                        !
  x----------------------------------------x
```

The daemon (`pnetd`) implements:
- Custom recursive routing protocol called ipchains which is used for both node-to-node and manager-to-node communication (which could actually be simplified to just node-to-node since manager is a node too)
- In-memory node database
- Daemon-Manager communication protocol

The manager (`pnet`) provides transport for daemons via `pnet-connect` and transport for application layer programs via `pnet-tunnel`, with both subcommands sharing a similar interface.

`pnetd` and `pnet` communicate via UNIX socket at /var/run/pnet (or custom path defined by $PNET_SOCKET_PATH)

## Examples
```sh
# run daemon with ioshd posing as tunnel process
pnetd ioshd

# connect to eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= via "socat udp:example.com:47210 -"
pnet connect -n eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= "socat udp:example.com:47210 -"
# replace TCP/IP on eth0 with pnet protocol and communicate with eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= on other end
pnet connect -n eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= "socat interface:eth0 -"
# connect to eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= via bluetooth socket on channel 3
pnet connect -n eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= "rfcomm connect /dev/rfcomm0 00:B0:D0:63:C2:26 3"
# introduce eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= to the network when it's connection is accepted by `socat udp-l:47210`
socat udp-l:47210 exec:"pnet connect -n eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= -"
# intrdouce all nodes that are accepted by `socat udp-l:47210` to the network
socat udp-l:47210,fork exec:"pnet connect -"

# create pnet0 network interface connected to eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg=
pnet tunnel eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= "socat tun,iff-up,device-name=pnet0 -"
# connect iosh to ioshd provided as the tunnel process of eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg=
iosh -t "pnet tunnel eU1WsfX5Hsig3DMi2ClOfkICz7uhzLnPiYY1RqSYwTg= -" zsh -l
```
