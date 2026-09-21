# PRD — Redis Enterprise on Outscale: the *run* half

> ⚠️ **Largely INFERRED.** Reconstructed on 2026-09-21 from code, git history and the Build
> repo's docs, because no product doc existed in this repo. The **Context** section is
> VERIFIED (stated by the maintainer / readable in the Build repo). Everything under
> *Problem*, *Users* and *Success* is a reasoned guess — **confirm or correct it**, then
> delete this banner. Open questions are collected at the bottom.

## Context (VERIFIED)

Two repos, two owners, one delivery:

| | `OSC-RedisEnterprisePacker-Build` | `OSC-RedisEnterprisePacker-Run` (this) |
|---|---|---|
| Owner | **Redis** | **the Outscale customer** |
| Does | Packer-builds a Redis Enterprise 8.2.0-78 OMI on Ubuntu 22.04 | Provisions the network, boots N nodes from that OMI, forms the cluster |
| Ships | an OMI id (`ami-89fe7cac` today), `eu-west-2` only | bash scripts the customer reads and runs |
| Licence | out of scope — customer supplies their own tarball and licence | — |

Outscale is the French sovereign cloud (a Dassault Systèmes subsidiary). The Build repo's own
findings note that a **SecNumCloud** deployment is a realistic target, and that *"the answer is
very likely 'no public exposure at all'"*.

## Problem (INFERRED)

Standing up a production-shaped Redis Enterprise cluster by hand on Outscale is a multi-hour,
error-prone job: an odd-numbered quorum spread across three subregions, ~40 distinct ports in
the security group, rack-aware placement, Auto Tiering on io1 volumes that Outscale misreports
as rotational, and a DNS zone delegated to the cluster itself. Getting any one of those wrong
yields a cluster that forms but misbehaves. This repo compresses that to two commands and
~5 minutes.

## Users (INFERRED)

1. **The Outscale customer's cloud/platform engineer** — the primary user. Runs the scripts in
   their own tenancy, reads them before running them, and is the reason security is the top
   axis. May be under SecNumCloud constraints. Likely runs from a VM inside Outscale rather
   than a laptop.
2. **A Redis Solution Architect** — runs it for demos, PoCs and enablement, on a throwaway
   network, and wants it torn down cheaply afterwards.

**VERIFIED** (maintainer intent, recorded in the Build repo's findings): the customer is
expected to be able to **supply the IDs of resources that already exist** in their account
instead of letting `osc-setup.sh` create a throwaway network. That dual-mode design already
works de facto but is **undocumented** (see `../tasks.md` F-26).

## In scope (VERIFIED from the code)

- Provision Net / Internet Service / route table / 3 public subnets / 1 security group.
- Boot **N nodes, N odd, 3 ≤ N ≤ 35**, round-robin across 3 subregions, from a given OMI.
- Optional **Flex / Auto Tiering**: 2× io1 volumes per node, RAID0 via `prepare_flash.sh`,
  with a udev `rotational=0` workaround for Outscale.
- Form the cluster: `rladmin cluster create` on node 1 (`rack_aware`), `cluster join` on the
  rest, `rack_id` = subregion.
- Emit the `A`/`NS` records the operator must publish so the cluster's own DNS serves
  `redis-<port>.<cluster-fqdn>`.
- Tear the whole thing down.

## Out of scope (VERIFIED — nothing in the tree provides it)

Image building (Build repo) · AWS or any other cloud (removed 2025-09-29, ADR 0005) ·
licence installation · DNS zone automation (records are printed, not published) ·
multi-region · load balancer · backups, monitoring, upgrades, day-2 operations ·
database creation (the operator does that in the UI).

## Success criteria (INFERRED — these are the ones to confirm)

1. From a clean account: `osc-setup.sh` then `cluster_instanciate.sh --nodes 3` yields a
   3-node, rack-aware, quorum-healthy cluster with the UI answering on `:8443`.
2. Wall clock stays ~5 min **regardless of N** (the stated goal of commit `10d933d`).
3. `tear_down_outscale.sh` leaves **zero** billable resources.
4. A customer can read every script end-to-end before running it — auditability is a feature,
   and part of why there is no IaC tool (ADR 0001).
5. No secret is ever written to a log, a terminal, or a process list. **Not met today** —
   `../tasks.md` F-05/F-06.
6. Defaults are safe for the customer's threat model. **Not met today** — `../tasks.md` F-02.
   Direction decided 2026-09-21: **two explicit modes**, `eval` and `production` — see ADR 0009.

## Non-functional requirements (INFERRED)

- **Security is the top axis** (VERIFIED as maintainer intent: *"the run script is used by the
  Outscale customer and must be secured"*). Today the shipped defaults are an evaluation
  topology, not a production one.
- **Portability:** POSIX-ish bash 5 + `oapi-cli` + `jq` + `ssh`, nothing else to install.
- **Idempotency / no orphans:** currently absent; `../tasks.md` F-20, F-29.
- **Cost honesty:** the customer must be billed for what they asked for. Currently violated —
  `../tasks.md` F-04.

## Known gap between intent and implementation

| Stated intent | Reality |
|---|---|
| "must be secured" | security group defaults to `0.0.0.0/0` on the admin plane and all DB ports (F-02) |
| "customer can provide their own resource IDs" | works, undocumented, unvalidated (F-26); and the node's IP detection assumes `10/8` (F-24) |
| ~~"a setup script that creates a net, network, **LB** etc."~~ | **Resolved 2026-09-21 (maintainer): there is deliberately no load balancer.** Redis Enterprise's own authoritative DNS handles endpoint resolution and failover, so an LB would be redundant. See ADR 0004 — its rationale is now VERIFIED, not inferred. |
| licence | `README.md` TODO "Ajout de la license"; Build's PRD says the customer supplies it (F-40) |

## Questions only the author can answer

**Answered 2026-09-21:**
- **Exposure model** → two explicit modes, `eval` and `production` (ADR 0009).
- **Load balancer** → deliberately none; the cluster's own DNS is the design (ADR 0004).
- **IaC** → stay on bash + `oapi-cli`; fix idempotency by porting Build's `env_file.sh` (ADR 0001).

Still open: see the end of `../tasks.md`.
