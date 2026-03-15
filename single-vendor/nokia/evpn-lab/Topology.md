### 1. Node & Underlay Infrastructure
| Node Name | Role  | System IP (Loopback) | BGP ASN | BGP Router ID | Underlay Policy |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **spine1** | Spine | `10.0.0.1/32` | 65000 | `10.0.0.1` | Import: `pass-all` / Export: `local` + `bgp` |
| **spine2** | Spine | `10.0.0.2/32` | 65000 | `10.0.0.2` | Import: `pass-all` / Export: `local` + `bgp` |
| **leaf1** | Leaf  | `10.0.0.11/32` | 65011 | `10.0.0.11` | Import: `pass-all` / Export: `local` + `bgp-evpn`|
| **leaf2** | Leaf  | `10.0.0.12/32` | 65012 | `10.0.0.12` | Import: `pass-all` / Export: `local` + `bgp-evpn`|

### 2. Point-to-Point Physical Links (Layer 3)
| Local Node | Local Interface | IP Address | Remote Node | Remote Interface |
| :--- | :--- | :--- | :--- | :--- |
| spine1 | `ethernet-1/1` | `192.168.11.0/31` | leaf1 | `ethernet-1/1` |
| spine1 | `ethernet-1/2` | `192.168.12.0/31` | leaf2 | `ethernet-1/1` |
| spine2 | `ethernet-1/1` | `192.168.21.0/31` | leaf1 | `ethernet-1/2` |
| spine2 | `ethernet-1/2` | `192.168.22.0/31` | leaf2 | `ethernet-1/2` |
| leaf1 | `ethernet-1/1` | `192.168.11.1/31` | spine1 | `ethernet-1/1` |
| leaf1 | `ethernet-1/2` | `192.168.21.1/31` | spine2 | `ethernet-1/1` |
| leaf2 | `ethernet-1/1` | `192.168.12.1/31` | spine1 | `ethernet-1/2` |
| leaf2 | `ethernet-1/2` | `192.168.22.1/31` | spine2 | `ethernet-1/2` |

### 3. EVPN Overlay & Virtualization (Layer 2)
| Node | MAC-VRF Name | VNI | Route Target | VXLAN Interface | Client Access Port |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **leaf1** | `mac-vrf-1` | 100 | `target:65000:100` | `vxlan1.1` | `ethernet-1/3.1` |
| **leaf2** | `mac-vrf-1` | 100 | `target:65000:100` | `vxlan1.1` | `ethernet-1/3.1` |

### 4. End Host Clients
| Client Node | Connected To | Interface | IP Address / Subnet | Default Gateway |
| :--- | :--- | :--- | :--- | :--- |
| **client1** | leaf1 (`e1/3`) | `eth1` | `172.16.100.1/24` | N/A (L2 Adjacency) |
| **client2** | leaf2 (`e1/3`) | `eth1` | `172.16.100.2/24` | N/A (L2 Adjacency) |