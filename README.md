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

**r2** is a minimalist networking framework that unifies local inter-process communication (IPC) and remote network connectivity through a single, elegant protocol. It enables seamless resource sharing, tunneling, and multiplexing across both local and distributed systems.

## Key Features

- **Unified Networking**: Treat local processes and remote nodes identically through a consistent interface
- **Simple Routing Protocol**: Single-hop routing that can be composed for complex topologies
- **Transparent Multiplexing**: Multiple virtual connections over single physical links
- **Flexible Transport**: Works over any transport layer (TCP/IP, UDP, Bluetooth, Unix sockets, serial, etc.)
- **Service Discovery**: Automatic resource advertisement and discovery across the network
- **Minimal Dependencies**: Small footprint with maximal flexibility

## The Route-to Protocol

At the heart is the Route-To protocol, defined by the simple operation:
```
r2 f n0 (RouteTo n1 msg) = f n1 (RoutedFrom n0 msg)
```

This minimalist design supports:
- **Routing**: Single-hop routing that can be recursively composed
- **Multiplexing**: Virtual nodes for shared channel communication
- **Tunneling**: Raw data streams through virtual node occupation
- **Ping**: Built-in connectivity testing (when n0 = n1)

## Components

### Core Daemon (`r2d`)
The background service that manages node connections, routing, and resource exposure. Each daemon instance represents a node in the network.

### Management CLI (`r2`)
Command-line interface for interacting with local daemons, connecting to remote nodes, and managing network resources.

### Connection Handlers
- **`r2-connect`**: Establishes connections between daemons over various transports
- **`r2-tunnel`**: Creates application-layer tunnels through the network
- **`r2-serve`**: Exposes local services to the network

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
Run r2d as a system service to provide network connectivity to all local applications.

### As a Library
Embed r2net functionality directly into your applications.

### As Standalone Binaries
Use individual components (`r2`, `r2d`, `r2-connect`, etc.) as needed.

### Via Adapters
Connect existing protocols and applications through r2net adapters.

## Project Status

Actively developed with a focus on stability and performance. The protocol is designed to be extensible while maintaining backward compatibility.

---

Where IPC meets networking through minimalist design. Connect everything, everywhere, with elegance.
