# r2net (route-to network)
## Overview
```
                               x----------------------------------------x
                               |                                        |
               ┌───────────┐ ┌────┐   ┌────┐  ┌────────────┐            |
          ┌────┤ r2 tunnel ├─┤proc│ ┌─┤proc├──┤ r2 connect ├────┐       |
          │    └───────────┘ └────┘ │ └────┘  └────────────┘    │       |
┌────┐ ┌──┴──┐                      │                        ┌──┴──┐ ┌────┐
│proc├─┤ r2d │                      └─┐                      │ r2d ├─┤proc│
└────┘ └──┬──┘                        │                      └──┬──┘ └────┘
  |       │    ┌────────────┐  ┌────┐ │ ┌────┐ ┌───────────┐    │
  |       └────┤ r2 connect ├──┤proc├─┘ │proc├─┤ r2 tunnel ├────┘
  |            └────────────┘  └────┘   └────┘ └───────────┘
  |                                        !
  x----------------------------------------x
```

Daemon (`r2d`) and manager (`r2`) implement route-to protocol, which they both use to reach far nodes, provide resources to the network and implement multiplexing. `r2-connect` expects a daemon on stdio and connects it to it's daemon, while `r2-tunnel` expects an application layer program on stdio and connects it to application layer programs of other daemons. `r2d` and `r2` communicate over a UNIX socket

## Route-to
At the core of this network is r2 protocol which is used for routing, multiplexing, tunneling and even ping at the same time while being as simple as `r2 f n0 (RouteTo n1 msg) = f n1 (RoutedFrom n0 msg)`

r2 only supports single-hop routing, which is sufficient to implement _any_ routing (through recursion). Both multiplexing and tunneling are handled by node exposing a virtual node with an agreed-upon Int256 identifier. For multiplexing, the virtual node communicates using the same protocol on its channel, while in case of tunneling, the virtual node occupies the entire channel with raw tunnel (stdio/process) data

r2 is ping as long as n0 equals n1

## Examples
```sh
# run daemon with ioshd posing as tunnel process
r2d ioshd

# connect to 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC via "socat udp:example.com:47210 -"
r2 connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "socat udp:example.com:47210 -"
# replace TCP/IP on eth0 with r2 protocol and communicate with 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC on other end
r2 connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "socat interface:eth0 -"
# connect to 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC via bluetooth socket on channel 3
r2 connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "rfcomm connect /dev/rfcomm0 00:B0:D0:63:C2:26 3"
# introduce 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC to the network when it's connection is accepted by `socat udp-l:47210`
socat udp-l:47210 exec:"r2 connect -n 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC -"
# intrdouce all nodes that are accepted by `socat udp-l:47210` to the network
socat udp-l:47210,fork exec:"r2 connect -"

# create r20 network interface connected to 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC
r2 tunnel 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC "socat tun,iff-up,device-name=r20 -"
# connect iosh to ioshd provided as the tunnel process of 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC
iosh -t "r2 tunnel 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC -" zsh -l
```
