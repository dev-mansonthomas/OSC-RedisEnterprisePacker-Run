# ADR 0004 — A public IP on every node, and Redis Enterprise as its own authoritative DNS

**Status:** Accepted · **security-contested**

## Decision
Every node sits in a public subnet with an auto-assigned public IP. Client and UI
reachability is delivered by delegating a DNS zone to the cluster itself: each node is
published as both an `A` record and an `NS` for the cluster zone.

## Evidence (VERIFIED)
- `osc-setup.sh:111-114` — `UpdateSubnet --MapPublicIpOnLaunch true` on all three subnets.
- `osc-setup.sh:190-199` — udp 53 and 5353 opened to `0.0.0.0/0`.
- `cluster_instanciate.sh:167-179` — emits `nsN.<zone> A <ip>`, `<zone> A <ip>` and
  `<zone> NS nsN.<zone>.` for **every** node (NS-for-all-nodes added in `10d933d`).
- `create-or-join-redis-cluster.sh` passes the node's **public** IP as `external_addr`.
- No `CreateLoadBalancer` / `CreateNatService` call exists anywhere.

## Rationale (VERIFIED — confirmed by the maintainer 2026-09-21)
Redis Enterprise's own DNS is what makes database endpoints
(`redis-<port>.<cluster-fqdn>`) resolve and fail over. Delegating the zone to the cluster is
the vendor-supported pattern, and public IPs are the shortest path to a cluster the customer
can reach from a laptop for evaluation.

## Consequences
- **Accepted:** database endpoints and failover work exactly as documented by Redis, with no
  load balancer to configure. **The absence of a load balancer is deliberate, not an omission**
  (confirmed 2026-09-21): the cluster's own DNS makes one redundant.
- **Cost / risk:** the Redis Enterprise admin UI (8443), the REST API (9443) and the entire
  database port range 10000-19999 are reachable from the whole internet as shipped
  (`F-02`). The product framing says this script is for customers and *must be secured* —
  as written it is an evaluation topology, not a production one.
- The delegated-zone design also requires the operator to hand-edit their DNS, which is the
  one manual step in an otherwise automated flow.
- A private-only variant (no public IPs, run from a bastion inside the tenancy, customer-
  supplied Net/Subnet/SG) is a stated requirement and is **not implemented** (`F-26`).
  Superseded in part by **ADR 0009**, which makes it the `production` mode.
