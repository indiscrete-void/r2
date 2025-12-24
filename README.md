# r2net (Route-to network)
## Overview
```
                                          ┌───────────────────────────────────────────────────┐  
                                          │                                                   │  
                          ┌───────────┐ ┌─┴──┐   ┌────┐  ┌────────────┐                       │  
                     ┌────┤ r2 tunnel ├─┤proc│ ┌─┤proc├──┤ r2 connect ├────┐                  │  
                     │    └───────────┘ └────┘ │ └────┘  └────────────┘    │                  │  
┌────┐ ┌────────┐ ┌──┴──┐                      │                        ┌──┴──┐ ┌────────┐ ┌──┴─┐
│proc├─┤r2 serve├─┤ r2d │                      └─┐                      │ r2d ├─┤r2 serve├─┤proc│
└─┬──┘ └────────┘ └──┬──┘                        │                      └──┬──┘ └────────┘ └────┘
  │                  │    ┌────────────┐  ┌────┐ │ ┌────┐ ┌───────────┐    │                     
  │                  └────┤ r2 connect ├──┤proc├─┘ │proc├─┤ r2 tunnel ├────┘                     
  │                       └────────────┘  └────┘   └──┬─┘ └───────────┘                          
  │                                                   │                                          
  └───────────────────────────────────────────────────┘                                          
```

Daemon (`r2d`) and manager (`r2`) implement route-to protocol, which they both use to reach far nodes, provide resources to the network and implement multiplexing. `r2-connect` expects a daemon on stdio and connects it to it's daemon, while `r2-tunnel` expects an application layer program on stdio and connects it to application layer programs of other daemons. `r2d` and `r2` communicate over a UNIX socket

## Route-to
At the core of this network is r2 protocol which is used for routing, multiplexing, tunneling and even ping at the same time while being as simple as `r2 f n0 (RouteTo n1 msg) = f n1 (RoutedFrom n0 msg)`

r2 only supports single-hop routing, which is sufficient to implement _any_ routing (through recursion). Both multiplexing and tunneling are handled by node exposing a virtual node with an agreed-upon identifier. For multiplexing, the virtual node communicates using the same protocol on its channel, while in case of tunneling, the virtual node occupies the entire channel with raw tunnel (stdio/process) data

r2 is ping as long as n0 equals n1

## Examples
### High-level
```toml
# /home/usual/.config/r2/alice.toml
[self]
addr = "alice"
socket = "/home/usual/.local/r2/alice.sock"
cmd = "echo hello from alice"

[[conn]]
addr = "bob"
cmd = "socat tcp-l:47210,fork,reuseaddr exec:-%"
```

```toml
# /home/usual/.config/r2/bob.toml
[self]
addr = "bob"
socket = "/home/usual/.local/r2/bob.sock"
cmd = "echo Hello, im bob"

[[conn]]
addr = "alice"
cmd = "socat tcp:127.0.0.1:47210 -"
```

```sh
usual@pop-os:~/projects/r2 (=) % r2dm -f ~/.config/r2/alice.toml &
[1] 95688
comunicating over "/home/usual/.local/r2/alice.sock"                                                                                                                                                         
starting conn ResolvedNegativeConnectionCmd "socat tcp-l:47210,fork,reuseaddr exec:'r2  --socket /home/usual/.local/r2/alice.sock connect -n bob -'" (bob)

usual@pop-os:~/projects/r2 [fg: 1] (=) % r2dm -f ~/.config/r2/bob.toml &  
[2] 95716
comunicating over "/home/usual/.local/r2/bob.sock"                                                                                                                                                           
starting conn PositiveConnectionCmd "socat tcp:127.0.0.1:47210 -" (alice)
accepted unknown node over Socket
connection established with bob over Socket
connection established with bob/child/F1F8uE2HmZYYQivQtSLGMp9Bvy7LyB1B8C5PC9EiXed9 over Socket
<-bob/child/F1F8uE2HmZYYQivQtSLGMp9Bvy7LyB1B8C5PC9EiXed9: connecting alice over Process "socat tcp:127.0.0.1:47210 -"
connection established with alice over R2 bob/child/F1F8uE2HmZYYQivQtSLGMp9Bvy7LyB1B8C5PC9EiXed9
comunicating over "/home/usual/.local/r2/alice.sock"
accepted unknown node over Socket
connection established with alice/child/A2DuXJpGQbxE2gNbv4qiqiAsrv9EeESDrxtFbra3ERnw over Socket
connection established with alice over Socket
connection established with bob over Pipe Stdio
connection established with alice over Pipe (Process "socat tcp:127.0.0.1:47210 -")
connection established with bob over R2 bob
connection established with alice over R2 alice
<-alice/child/A2DuXJpGQbxE2gNbv4qiqiAsrv9EeESDrxtFbra3ERnw: connecting bob over Stdio
connection established with bob over R2 alice/child/A2DuXJpGQbxE2gNbv4qiqiAsrv9EeESDrxtFbra3ERnw

usual@pop-os:~/projects/r2 [fg: 2] (=) % r2 -s ~/.local/r2/alice.sock -t bob ls
comunicating over "/home/usual/.local/r2/alice.sock"
accepted unknown node over Socket
connection established with alice/child/F5BiNC5Qu4KYLmNMQBeWn57tM3Cvi8KHrqfzd8RZvbyp over Socket
connection established with alice over Socket
connection established with bob over R2 alice
connection established with alice/child/F5BiNC5Qu4KYLmNMQBeWn57tM3Cvi8KHrqfzd8RZvbyp over R2 alice
<-alice/child/F5BiNC5Qu4KYLmNMQBeWn57tM3Cvi8KHrqfzd8RZvbyp: listing connected nodes
->alice/child/F5BiNC5Qu4KYLmNMQBeWn57tM3Cvi8KHrqfzd8RZvbyp: ResNodeList [alice/child/F5BiNC5Qu4KYLmNMQBeWn57tM3Cvi8KHrqfzd8RZvbyp,alice,bob/child/F1F8uE2HmZYYQivQtSLGMp9Bvy7LyB1B8C5PC9EiXed9]
[alice/child/F5BiNC5Qu4KYLmNMQBeWn57tM3Cvi8KHrqfzd8RZvbyp,alice,bob/child/F1F8uE2HmZYYQivQtSLGMp9Bvy7LyB1B8C5PC9EiXed9]
alice/child/F5BiNC5Qu4KYLmNMQBeWn57tM3Cvi8KHrqfzd8RZvbyp disconnected
```

### Low-level
```sh
# run daemons
r2d default
r2d alice
r2d bob


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


# exposes aaaa/service/sshd
r2 -s /run/aaaa.sock serve "sshd -i"

# exposes aaaa/service/ioshd 
r2 -s /run/aaaa.sock serve ioshd

# exposes aaaa/service/vpn
r2 -s /run/aaaa/sock serve -n vpn "socat tun,iff-up,device-name=r20 -"


# create r20 network interface connected to 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC
r2 -t 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC -t vpn tunnel "socat tun,iff-up,device-name=r20 -"

# connect iosh to ioshd provided as the tunnel process of 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC
iosh "r2 -t 6Xb2RtEfug8nxD6A7Afvd3SPt4ePCibjFHLcyRqVqFgC -t ioshd tunnel -" zsh -l

# ssh-tunneling
r2-ssh alice # ssh -o ProxyCommand="r2 -t alice -t service/sshd tunnel -" r2/alice
```
