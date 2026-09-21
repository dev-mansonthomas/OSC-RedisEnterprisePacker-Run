# ADR 0009 — Two explicit exposure modes: `eval` and `production`

**Status:** **Accepted 2026-09-21 — not yet implemented.** Unlike ADRs 0001-0008 this is a
*forward* decision, not one read off the code. Tracked as `../tasks.md` F-02 / F-10 / F-26.

## Context

As shipped, `osc/osc-setup.sh` hardcodes source `0.0.0.0/0` on every external security-group
rule, so the Redis Enterprise admin UI (8443), the REST API (9443, 3346) and the whole
database port range (10000-19999) are reachable from the public internet. The port *list* is
correct and required; the source CIDR is the defect.

Two constraints pull in opposite directions:

- This repo is run by **the customer**, in their tenancy, potentially under **SecNumCloud**,
  where the right answer is very likely *no public exposure at all*.
- It is also the enablement/PoC path, where a Solution Architect wants a cluster reachable
  from a laptop in five minutes on a throwaway network.

A single default cannot serve both, and "public by default with a warning" means the unsafe
option is the one that happens when nobody reads the docs.

## Decision

Make the exposure choice **explicit and unavoidable** via a mode switch rather than a default:

| | `eval` | `production` |
|---|---|---|
| Network | throwaway, created by `osc-setup.sh` | **bring-your-own** (customer-supplied `OSC_*` IDs), validated before use |
| Node addressing | public IPs | private subnets; admin access via a bastion |
| `OPERATOR_CIDR` (SSH, 8443, 9443, 3346) | must be given explicitly; `0.0.0.0/0` allowed only with `--allow-public` | required, no public value accepted |
| `CLIENT_CIDR` (DB ports, 8001, DNS) | defaults to the Net CIDR | required |
| Cleartext REST `8080` | closed | closed |
| Host `ufw` | re-scoped via `/usr/local/sbin/redis-enterprise-firewall` | same |

Flag names must match the image's `redis-enterprise-firewall` tool (`--cluster-cidr`,
`--client-cidr`, `--operator-cidr`) so the two firewalls are configured from one vocabulary.

## Rationale

- The customer already owns the exposure decision in the bring-your-own-network case; the
  mode switch simply stops pretending that case does not exist (it already works de facto —
  `F-26`).
- Naming the modes makes the *eval* topology honestly disposable, and stops it from being
  mistaken for a deployable reference.
- Keeping one CIDR vocabulary across the Outscale security group and the in-image `ufw`
  avoids the two firewalls drifting — which they already have (`F-03`, `F-18`).

## Consequences

- `osc-setup.sh` grows a mode parameter and CIDR variables; `_my_env.template.sh` grows
  `OPERATOR_CIDR` / `CLIENT_CIDR`.
- `production` mode requires work that does not exist yet: private subnets, NAT for egress,
  a bastion path, and validation of customer-supplied resource IDs (`ReadSubnets`,
  `ReadSecurityGroups`, plus a check that the three subnets are in three distinct subregions).
- `F-24` becomes blocking rather than latent: the node bootstrap detects its own address with
  `grep '^10\.'`, which fails on a customer network in `172.16/12` or `192.168/16`.
- `configure_node()` must invoke the image's firewall tool with the mode's CIDRs (`F-41`).
- The README must lead with the mode choice. The interim version written on 2026-09-21
  documents both paths as "Mode A / Mode B" and warns about the current default.

## Alternatives rejected

- **Private-only default.** Correct for production, but silently breaks the laptop-demo flow
  that the repo is also used for.
- **Public default + a knob.** Least disruptive, but still ships an unsafe default — which is
  precisely the finding (`F-02`).
