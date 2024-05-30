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

Both daemon (`pnetd`) and manager (`pnet`) implement recursive routing protocol called r2 (route to), which they both use to provide resources as r2 reachable nodes. `pnet-connect` expects a daemon on stdio and connects it to the daemon, while `pnet-tunnel` expects an application layer program on stdio and connects it to other daemons' application layer programs. `pnetd` and `pnet` communicate over a UNIX socket

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
