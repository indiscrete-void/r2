# r2
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

r2 is a network stack that unifies local inter-process communication (IPC) and remote network connectivity through a single, elegant model. It enables seamless resource sharing, tunneling, and multiplexing across both local and distributed systems.

Composable like [socat](https://linux.die.net/man/1/socat)  
Ready to use like [Wireguard](https://www.wireguard.com/) and [Yggdrasil](https://yggdrasil-network.github.io/)  
Universal like [ZeroMQ](https://zeromq.org/) and [libp2p](https://libp2p.io/)  

[=> Philosophy <=](https://gitlab.com/-/snippets/4929538)

## Key Features
- **Unified Networking**: Treat local processes and remote nodes identically through a consistent interface ✅
- **Declarative Address Scheme**: Name entities freely ✅ or by cryptographic identity ⏳ use combinators ✅ and constraints ⏳ for operations 
- **Scoped Networks**: Distinguish local ✅, domain-specific ⏳ and global resources ⏳ by address
- **Advanced Application Layer**: Use built-in DHT ⏳ and communication models for service/client ✅, pub/sub ⏳ or full blown blockchain (consistent history) semantics ⏳
- **Service Discovery**: Automatic resource advertisement and discovery across the network ⏳
- **Self-constructing**: Reach anyone with Kademlia and fault-tolerant spanning trees ⏳
- **Multipathing**: Combine multiple underlying links into single connection ⏳
- **Multiplexing**: Multiple virtual connections over single physical links ✅
- **Flexible Transport**: Works over any transport layer (TCP/IP, UDP, Bluetooth, Unix sockets, serial, etc.) that can be reduced to stdio ✅
- **Simple Core Protocol**: Single-hop routing that can be composed for complex topologies ✅
- **Multiplatform**: Linux/FreeBSD ✅, Windows ⏳, Mobile ⏳, Web ⏳, Microcontrollers ⏳

## Address Scheme
r2 uses a flexible, declarative addressing system that can represent anything from simple process names to complex cryptographic identities and routing patterns.
- **Free identifiers**: Simple names like `iota` or `telegram-bot` ✅
- **Tagged identifiers**: `tag:value` pairs for typed addresses, e.g.: ✅
    * `x25519:oJK8NJELY3IcgzMyG2F9PMrEspqAe7eeUMxmjHWwwXc=` – cryptographic identity from global network
    * `sha256:ef66ac0e994ab54877743f5608847d835a116d61a97b1caa8fdfb74156922496` - content identity
    * `service:cat` – a named service
    * `child:1337` – a specific child process or virtual node
    * `topic:chat` – a pub/sub topic
    * `net:home` - domain-specific network `home`
- **Hierarchical addresses**: Path-like notation `iota/alice/bob` meaning bob is reachable through alice via iota ✅
- **Logical addresses for rules and patterns**: ⏳
    * Patterns with wildcards: `*/service:cat` matches any node offering the cat service
    * Alternation: `(alice|bob)/service:cat` matches either Alice's or Bob's cat service
    * Predicates: `?secure` to match nodes based on properties
- **Sets**: Comma-separated lists like `bogdan, theodor, x25519:oJK8NJELY3IcgzMyG2F9PMrEspqAe7eeUMxmjHWwwXc=` ⏳
- **Self reference**: self always refers to the local node ⏳

Complex examples:  
- `net:home/*` - anything from home network
- `alice/*/service:cat` – any cat service reachable via Alice
- `?encrypted */service:chat` – any chat service that is encrypted

## The Route-to Protocol

At the heart is the Route-To protocol, defined by the simple operation:
```
r2 f n0 (RouteTo n1 msg) = f n1 (RoutedFrom n0 msg)
```

This minimalist design supports:
- **Routing**: Single-hop routing that can be recursively composed
- **Multiplexing**: Virtual nodes for shared channel communication
- **Services**: Raw data streams through virtual node occupation
- **Ping**: Built-in connectivity testing (when n0 = n1)

## Binaries

### Core Daemon (`r2d`)
The background service that manages topology. Each daemon instance represents a node in the network.

### Management CLI (`r2`)
Command-line interface for interacting with local daemons: connecting to remote nodes, and exposing network resources.

### High Level Manager (`r2dm`)
Declare networks and daemons in a single config which is then implemented by `r2d` and `r2` composition

## Getting Started

### Basic Example

**Alice's configuration (`~/.config/r2/alice.toml`):**
```toml
[self]
addr = "alice"
socket = "/home/user/.local/r2/alice.sock"
cmd = "echo hello from alice"

[[conn]]
addr = "bob"
cmd = "socat tcp-l:47210,fork,reuseaddr exec:-"
```

**Bob's configuration (`~/.config/r2/bob.toml`):**
```toml
[self]
addr = "bob"
socket = "/home/user/.local/r2/bob.sock"
cmd = "echo Hello, I'm bob"

[[conn]]
addr = "alice"
cmd = "socat tcp:127.0.0.1:47210 -"
```

**Starting the network:**
```bash
# Start Alice's daemon
r2dm -f ~/.config/r2/alice.toml &

# Start Bob's daemon  
r2dm -f ~/.config/r2/bob.toml &

# Connect to Bob from Alice
r2 -s ~/.local/r2/alice.sock -t bob ls
```

## Advanced Usage

### Multi-Transport Connectivity
```bash
# Connect via UDP
r2 connect -n <node-id> "socat udp:example.com:47210 -"

# Connect via Bluetooth (RFCOMM)
r2 connect -n <node-id> "rfcomm connect /dev/rfcomm0 00:B0:D0:63:C2:26 3"

# Connect via network interface (raw packets)
r2 connect -n <node-id> "socat interface:eth0 -"
```

### Service Exposure
```bash
# Expose SSH daemon as a network service
r2 -s /run/node.sock serve "sshd -i"

# Expose custom service
r2 -s /run/node.sock serve ioshd

# Create VPN tunnel interface
r2 -s /run/node.sock serve -n vpn "socat tun,iff-up,device-name=r20 -"
```

### Network Tunneling
```bash
# Create network interface connected to remote node
r2 -t <node-id> -t vpn tunnel "socat tun,iff-up,device-name=r20 -"

# Interactive shell through tunnel
iosh "r2 -t <node-id> -t ioshd tunnel -" zsh -l

# SSH tunneling
r2-ssh <node-id>  # Equivalent to: ssh -o ProxyCommand="r2 -t <node-id> -t service/sshd tunnel -" r2/<node-id>
```

### Connection Brokering
```bash
# Accept incoming connections and introduce them to the network
socat udp-l:47210 exec:"r2 connect -n <node-id> -"

# Fork for multiple incoming connections
socat udp-l:47210,fork exec:"r2 connect -"
```

## Installation & Usage

### As a Super-Server
Run r2dm as a system service to provide network connectivity to all local applications.

### As a Library
Embed r2 functionality directly into your applications.

### As Standalone Binaries
Use individual components (`r2`, `r2d`, `r2-connect`, etc.) as needed.

### Via Adapters ⏳
Connect existing protocols and applications through r2 adapters. TCP/IP (via TUN), REST and proxy-site are planned 

---

Where IPC meets networking through minimalist design. Connect everything, everywhere, with elegance.
