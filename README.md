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
- Recursive routing protocol
- Manager communication protocol
- In-memory node database

The manager (`pnet`) provides transport for daemons via `pnet-connect` and transport for application layer programs via `pnet-tunnel`, with both subcommands sharing a similar interface.

`pnetd` and `pnet` communicate via UNIX socket at /var/run/pnet (or custom path defined by $PNET_SOCKET_PATH)

## Examples
```sh
# run daemon with ioshd posing as tunnel process
pnetd ioshd

# connect to 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC via "socat udp:example.com:47210 -"
pnet connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "socat udp:example.com:47210 -"
# replace TCP/IP on eth0 with pnet protocol and communicate with 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC on other end
pnet connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "socat interface:eth0 -"
# connect to 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC via bluetooth socket on channel 3
pnet connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "rfcomm connect /dev/rfcomm0 00:B0:D0:63:C2:26 3"
# introduce 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC to the network when it's connection is accepted by `socat udp-l:47210`
socat udp-l:47210 exec:"pnet connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC -"
# intrdouce all nodes that are accepted by `socat udp-l:47210` to the network
socat udp-l:47210,fork exec:"pnet connect -"

# create pnet0 network interface connected to 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC
pnet tunnel 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "socat tun,iff-up,device-name=pnet0 -"
# connect iosh to ioshd provided as the tunnel process of 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC
iosh -t "pnet tunnel 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC -" zsh -l
```
