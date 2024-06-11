# pnet (Pandora Network)
## Overview
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

Daemon (`pnetd`) and manager (`pnet`) implement r2 (route to) protocol, which they both use to reach far nodes, provide resources to the network and implement multiplexing. `pnet-connect` expects a daemon on stdio and connects it to it's daemon, while `pnet-tunnel` expects an application layer program on stdio and connects it to application layer programs of other daemons. `pnetd` and `pnet` communicate over a UNIX socket

## r2
At the core of pnet is r2 protocol which is used for multiplexing, tunneling and routing at the same time while being as simple as `r2 SendTo n0 (RouteTo n1 msg) = SendTo n1 (RoutedFrom n0 msg)`

r2 only supports single-hop routing, which is sufficient to implement _any_ routing (through recursion). Both multiplexing and tunneling are handled by node exposing a virtual node with an agreed-upon Int256 identifier. For multiplexing, the virtual node communicates using the same protocol on its channel, while in case of tunneling, the virtual node occupies the entire channel with raw tunnel (stdio/process) data

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
