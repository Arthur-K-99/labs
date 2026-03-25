# Modern Data Center Fabric (EVPN-VXLAN over eBGP)

## 1. Introduction to the Architecture

### The Paradigm Shift

For decades, the standard for building data center networks was the traditional 3-tier architecture: Core, Distribution, and Access. This model was heavily optimized for "North-South" traffic—data moving vertically in and out of the data center to the internet or campus users.

However, the rise of modern applications, virtualization, microservices, and distributed storage completely changed the traffic landscape. Today, the vast majority of traffic is "East-West"—servers talking to other servers within the same data center. The legacy 3-tier model struggles with this shift, often funneling traffic up through choke points at the distribution or core layers. Furthermore, it traditionally relied on Spanning Tree Protocol (STP) to block redundant links to prevent network loops, effectively leaving half of the expensive physical bandwidth sitting idle.

The solution to this bottleneck is the **Spine-Leaf** architecture.

### What is Spine-Leaf?

Based on the Clos network topology (originally mathematically modeled for telephone switching in the 1950s), the Spine-Leaf architecture flattens the data center network into just two functional tiers:

* **Spines (The Backbone):** These switches provide the high-speed routing core. They connect *only* to the leaf switches. They do not connect to each other, and they never connect directly to end hosts or servers.
* **Leaves (The Edge):** These switches act as the access layer. They connect to the endpoints—servers, firewalls, routers, and load balancers. Crucially, **every single leaf switch connects to every single spine switch.**

This interconnected mesh introduces several massive engineering advantages:

* **Predictable Latency:** No matter where two servers are located in the data center, they are always exactly the same number of network "hops" away from each other. The traffic path is always: *Source Leaf -> Spine -> Destination Leaf*.
* **Active-Active Bandwidth:** Because Layer 2 STP is replaced by Layer 3 routing protocols, loop blocking is eliminated. A leaf switch can use all of its physical uplinks to the spines simultaneously, utilizing Equal-Cost Multi-Path (ECMP) to load-balance traffic across the entire fabric.
* **Horizontal Scalability:** The network scales out gracefully. If the fabric needs more total bandwidth or lower oversubscription, you simply add another spine switch. If you need more physical ports for servers, you add another leaf switch.

### Real-World Application

This architecture is the undisputed standard for modern infrastructure design.

* **Hyperscalers and Cloud Providers:** Public cloud environments rely on massive-scale Spine-Leaf fabrics to route petabytes of east-west data between tens of thousands of compute nodes seamlessly.
* **ISPs and Telcos:** Telecommunications providers use this design to build distributed, high-throughput edge data centers capable of handling 5G workloads.
* **Enterprise Data Centers:** Enterprises adopt this model to support heavily virtualized and containerized environments (like VMware, Kubernetes, or Proxmox clusters). It provides the high-speed, non-blocking backplane required for virtual machines to migrate between physical hosts seamlessly.

## 2. The Underlay: Building the Highway (Layer 3)

### The Purpose of the Underlay

If the data center fabric is a highway system, the underlay is the actual asphalt. Its sole responsibility is to provide rock-solid, loop-free, high-speed IP reachability between the networking devices themselves.

The underlay **does not care** about the servers, the virtual machines, or the tenant MAC addresses. It has one job: make sure that Leaf 1 can reach Leaf 2's loopback address across the Spines. Once that fundamental IP reachability is established, the overlay (which we will cover next) can ride on top of it.

### Addressing Strategy

To build this highly efficient physical network, we use a very specific IP addressing scheme designed to conserve space and provide maximum stability:

* **`/31` Point-to-Point Transit Links:** Traditionally, network engineers used `/30` subnets for point-to-point links, which wasted two IP addresses per link (the network and broadcast addresses). In modern fabrics, we use `/31` subnets. A `/31` provides exactly two usable IPs—one for the Spine's interface and one for the Leaf's interface. When you have hundreds of links in a data center, this efficiency is mandatory.
* **`/32` System Loopbacks:** Every switch is assigned a `/32` loopback address. Unlike a physical port, a loopback is a virtual interface that never goes down unless the switch completely loses power. This `/32` address serves two critical roles: it acts as the router's BGP identifier (Router ID), and it acts as the anchor point (VTEP) for the virtual VXLAN tunnels.

### eBGP at Scale

Historically, engineers used Interior Gateway Protocols (IGPs) like OSPF or IS-IS to build the underlay. While these work perfectly fine in smaller environments, they struggle at hyperscaler proportions. IGPs require every router to maintain a complete map of the entire network, which can consume massive amounts of CPU and memory when thousands of links are flapping or changing state.

Instead, modern data centers use **eBGP (External Border Gateway Protocol)** for the underlay. BGP is the protocol that runs the global internet. It is designed to handle millions of routes with extreme stability. It also provides unmatched traffic engineering and policy control, allowing engineers to dictate exactly how traffic flows through the fabric.

### ASN Design

To make eBGP work in a Spine-Leaf topology, we use a specific Autonomous System Number (ASN) allocation strategy:

* **The Spines share a single ASN** (e.g., AS 65000).
* **Every Leaf gets a unique ASN** (e.g., AS 65011, AS 65012, etc.).

This design naturally prevents routing loops using BGP's built-in AS-Path loop prevention mechanism. If Leaf 1 advertises a route, it tags it with AS 65011. The Spine receives it, adds AS 65000, and sends it to Leaf 2. If that route somehow loops back to Leaf 1, Leaf 1 will see its own ASN (65011) in the path and instantly discard it. Furthermore, having all Spines in the same ASN allows the Leaves to easily perform Equal-Cost Multi-Path (ECMP) load balancing across all available Spines without complex configuration.

### Routing Security (RFC 8212)

Modern network operating systems operate on a "secure by default" philosophy, heavily enforcing standards like **RFC 8212**. This standard dictates that an eBGP session will drop all incoming and outgoing routes unless an explicit routing policy tells it otherwise.

In a Spine-Leaf underlay, you cannot simply turn on BGP and expect it to work. You must explicitly configure:

* **Export Policies:** To tell the Leaves to advertise their local `/32` loopbacks to the fabric, and to tell the Spines to transit (pass along) the BGP routes they learn from one Leaf down to the others.
* **Import Policies:** To tell all switches to explicitly accept the IP routes being advertised by their neighbors.

Without these strict policies, the highway remains closed, and the foundation of the data center fails to form.

## 3. The Overlay: Packaging the Cargo (Layer 2 over Layer 3)

### The Problem: The Need for Layer 2 Adjacency

Even though we just built a highly efficient, routed Layer 3 highway, modern applications often throw a wrench in the works: they demand Layer 2 adjacency.

Features like VMware vMotion (moving a live virtual machine from one physical server to another) or legacy clustering software require the endpoints to be on the exact same IP subnet. If Server A is on Rack 1 and moves to Rack 2, it needs to keep its IP address and its default gateway.

Historically, networks solved this by stretching VLANs across the entire data center using Spanning Tree Protocol (STP). However, as we discussed, STP is disastrous at scale—it blocks redundant links, wastes bandwidth, and creates massive failure domains where a single broadcast storm can take down the whole building. We need the stability of our new Layer 3 routing, but we must provide the *illusion* of a single Layer 2 switch to the endpoints.

### VXLAN (The Data Plane)

To solve this, we use **VXLAN (Virtual eXtensible LAN)**. Think of VXLAN as the shipping container that carries our cargo across the highway.

Instead of stretching physical VLANs, VXLAN takes a standard Layer 2 Ethernet frame sent by a client, wraps it up (encapsulates it) inside a standard UDP/IP packet, and routes it across the underlay.

* **VTEP (VXLAN Tunnel Endpoint):** This is the interface on the Leaf switch that handles the packing and unpacking. It uses the Leaf's `/32` loopback address as the source and destination for the tunnels.
* **VNI (VXLAN Network Identifier):** This is the VXLAN equivalent of a VLAN tag. However, while traditional VLANs are limited to 4,096 IDs, VNIs are 24-bit, meaning you can have over 16 million unique isolated networks running across the same fabric.

### EVPN (The Control Plane)

While VXLAN handles the data forwarding, it still needs instructions. How does Leaf 1 know that Client 2's MAC address lives behind Leaf 2?

Standard switches use "flood-and-learn"—if they don't know where a MAC address is, they broadcast an ARP request out of every single port. In a massive data center, flooding ARP across thousands of switches would instantly crash the network.

Enter **EVPN (Ethernet Virtual Private Network)**. EVPN is a massive upgrade to the BGP protocol we used in the underlay. Instead of just advertising IP subnets, BGP EVPN is designed to advertise **MAC addresses**.
When Leaf 2 learns Client 2's MAC address on a physical port, it packages that MAC into an EVPN "Route Type 2" message and sends it to Leaf 1 via BGP. Now, Leaf 1 knows exactly which VTEP to send traffic to, completely eliminating the need for network-wide broadcast flooding.

### Over-The-Top (OTT) Peering

In a classic eBGP Spine-Leaf design, the EVPN peering is often configured "Over-The-Top."

Rather than peering EVPN with the Spines (which would require the Spines to process complex Layer 2 MAC tables), the Leaf switches establish direct, multihop eBGP EVPN sessions with *each other* using their loopback addresses.

The Spines are intentionally kept ignorant. To a Spine switch, a VXLAN packet just looks like a standard UDP packet moving from `10.0.0.11` to `10.0.0.12`. The Spines route it at line-rate without ever looking inside the payload, keeping the core of the network blisteringly fast and incredibly simple.

## 4. The Virtualization Layer: The Edge Connection

The underlay provides the routing highway, and the overlay provides the shipping containers. But how do the actual servers, virtual machines, and firewalls connect to this fabric without realizing they are traversing a massive Layer 3 network?

This is where the virtualization layer comes in, transforming the physical ports on the leaf switches into highly isolated virtual environments.

### MAC-VRFs (The Virtual Switches)

In a traditional network, you assign a physical port to a VLAN. In an EVPN-VXLAN fabric, you assign the physical port to a **MAC-VRF** (Virtual Routing and Forwarding instance for MAC addresses).

Think of a MAC-VRF as a completely independent, invisible virtual switch living inside the physical leaf router.

* It maintains its own isolated MAC address table.
* It binds the physical edge ports facing the servers directly to the logical VXLAN tunnel interfaces (VTEPs).
* When a server sends a frame into the physical port, the MAC-VRF grabs it, tags it with the correct VNI (VXLAN Network Identifier), and hands it off to the routing engine to be encapsulated and sent across the fabric.

### Route Distinguishers (RD) & Route Targets (RT)

Real-world data centers—especially public clouds or enterprise environments—need to host multiple tenants securely. Company A and Company B might both want to use the `10.0.0.0/24` subnet, and the fabric must keep their traffic completely separated. EVPN handles this multi-tenancy using two specific BGP attributes:

* **Route Distinguishers (RD):** Since BGP will drop identical routes, the RD is a unique identifier prepended to the MAC/IP address before it is advertised to the fabric. It makes a generic address mathematically unique (e.g., changing `AA:BB:CC:DD:EE:FF` into `TenantA:AA:BB:CC:DD:EE:FF`).
* **Route Targets (RT):** These are essentially colored tags attached to the BGP routes. When Leaf 1 advertises a MAC address for Tenant A, it attaches a specific RT (e.g., `target:65000:100`). When Leaf 2 receives that route, it looks at its own MAC-VRFs and asks, "Do I have any virtual switches configured to import the color `target:65000:100`?" If yes, it installs the route. If no, it ignores it. This guarantees secure, leak-proof isolation across the entire physical fabric.

### The Packet Walk: Tying It All Together

To truly understand the power of this architecture, let's trace exactly what happens on the wire when Client 1 (`172.16.100.1`) pings Client 2 (`172.16.100.2`) sitting on the other side of the data center.

1. **The Ingress:** Client 1 believes Client 2 is on the same local switch. It generates a standard ICMP Echo Request and an ARP broadcast to find Client 2's MAC address, sending it up the physical cable to Leaf 1.
2. **The Encapsulation:** Leaf 1 receives the frame on its physical port and places it into the MAC-VRF. It checks its BGP EVPN table and sees that Client 2's MAC address is reachable via Leaf 2's loopback address (`10.0.0.12`) on VNI `100`. Leaf 1 wraps the original Ethernet frame inside a VXLAN UDP packet, slapping a destination IP of `10.0.0.12` on the outer header.
3. **The Transit:** Leaf 1 forwards this UDP packet to the Spine layer using standard underlay IP routing. The Spine receives the packet, looks *only* at the outer destination IP (`10.0.0.12`), performs a standard routing lookup, and shoots it down the physical link to Leaf 2 at line-rate.
4. **The Decapsulation:** Leaf 2 receives the packet and recognizes its own loopback IP. It strips off the outer IP and UDP headers, revealing the VXLAN payload. Seeing VNI `100`, it drops the original, untouched Ethernet frame directly into the matching MAC-VRF.
5. **The Egress:** The MAC-VRF looks at the original destination MAC address, sees that it lives out a specific physical port, and forwards the frame down to Client 2.

To Client 1 and Client 2, they just had a standard Layer 2 conversation over a dumb switch. In reality, their traffic was elegantly routed across a highly scalable, multi-path, multi-tenant BGP superhighway.

## 5. Deployment

This lab uses Containerlab to spin up the virtual Nokia SR Linux nodes and Alpine Linux clients. 

**To deploy the lab:**
```bash
sudo clab deploy -t evpn-lab.clab.yml --reconfigure
```

**To destroy the lab:**
```bash
sudo clab destroy -t evpn-lab.clab.yml --cleanup
```

## 6. Verification & Testing

Once the lab is deployed, you can verify the fabric is passing traffic from the bottom up.

**1. Verify the Underlay (Routing Highway):**
Check that the eBGP sessions between the Spines and Leaves are established.
* `docker exec -it clab-evpn-lab-leaf1 sr_cli`
* `show network-instance default protocols bgp summary`

**2. Verify the Overlay (EVPN Control Plane):**
Check that the multihop eBGP sessions between the Leaf loopbacks are active and passing MAC routes.
* `show network-instance default protocols bgp routes evpn route-type summary`

**3. Verify the MAC-VRF (Virtual Switch):**
Confirm that the Leaf switch has learned the remote client's MAC address via the VXLAN tunnel.
* `show network-instance mac-vrf-1 bridge-table mac-table all`

**4. The End-to-End Ping (Data Plane):**
Finally, test Layer 2 adjacency across the routed fabric.
* `docker exec clab-evpn-lab-client1 ping -c 4 172.16.100.2`