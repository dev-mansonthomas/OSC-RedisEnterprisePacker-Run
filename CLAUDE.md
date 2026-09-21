# CLAUDE.md — OSC-RedisEnterprisePacker-Run

Entry map for agents. Reconstructed from code on **2026-09-21** (no prior handover).
Statements are **VERIFIED** (read/executed) or **INFERRED** (flagged inline).
Deep dives: `docs/architecture/overview.md`, `docs/tasks.md` (backlog), `docs/specs/`.

## What this is

Bash + `oapi-cli` automation that deploys a **Redis Enterprise cluster on Outscale**
(French sovereign cloud, Dassault subsidiary) from a pre-built OMI.

Two-repo system — **this repo is the *run* half, executed by the Outscale customer**:

- `../OSC-RedisEnterprisePacker-Build` — Packer build of the Redis Enterprise OMI (Redis-owned).
- `.` — provisions the Outscale network, boots N VMs from that OMI, and forms the cluster
  (node 1 `rladmin cluster create`, nodes 2..N `rladmin cluster join`).

**Because customers run it, security is the top axis.** See `docs/tasks.md` — the
`F-*` items are open findings, not hypotheticals.

## Stack

No compiler, no package manager, no tests. Pure POSIX-ish **bash 5** + `oapi-cli` + `jq` + `ssh`.
Comments and messages are a **French/English mix** — match the file you are editing.

## Layout

| Path | Role |
|---|---|
| `osc/osc-setup.sh` | Creates Net / InternetService / RouteTable / 3 Subnets / SecurityGroup. Appends `OSC_*` to `_my_env.sh`. |
| `osc/cluster_instanciate.sh` | **Main entry point.** `--nodes <odd 3..35> --parallel <0\|N>`. Orchestrates the whole cluster. |
| `osc/instanciate_image_outscale.sh` | Boots ONE VM (`--node-num`, `--subnet`). Waits for `running` + real SSH readiness. Appends its public IP. |
| `osc/destroy_cluster.sh` | **Deletes the VMs, keeps the network.** Use this between iterations — the Net is shared with the Build repo. Scoped to `redis-node-*` tags by default; `--timeout`, `-y`, `--all-vms`, `--keep-env`. |
| `osc/tear_down_outscale.sh` | Deletes VMs **then unwinds the whole network**, 7 steps. Destroys the shared Net — see gotcha 9. |
| `osc/connect_to_my_instance.sh <n>` | `ssh` to node *n*. |
| `image_scripts/create-or-join-redis-cluster.sh` | Runs **on the node** (scp'd + `sudo`). `init` → `rladmin cluster create`; `join` → `rladmin cluster join` with 10 retries × 30 s. |
| `_my_env.template.sh` | Config template → copy to `_my_env.sh` (gitignored). |

## How to run / test / build

**There is no build and no test suite.** The only credential-free verification that exists:

```sh
# syntax check — all 6 scripts pass (VERIFIED 2026-09-21)
for f in osc/*.sh image_scripts/*.sh; do bash -n "$f" || echo "FAIL $f"; done

# lint — 11 findings, 7 of them benign SC1091 (VERIFIED 2026-09-21)
shellcheck -f gcc osc/*.sh image_scripts/*.sh
```

A real run needs Outscale credentials and **is not possible from the dev VM**
(`oapi-cli` is intentionally absent there; credentials live on the host):

```sh
cp _my_env.template.sh _my_env.sh   # then edit it
cd osc && ./osc-setup.sh            # ~1 min, appends OSC_* to ../_my_env.sh
cd osc && ./cluster_instanciate.sh --nodes 3
# paste the printed A/NS records into your DNS zone, then open
# https://$OUTSCALE_CLUSTER_DNS:8443
cd osc && ./tear_down_outscale.sh   # destroys everything
```

Reported wall clock: **~5 min regardless of node count** (commit `10d933d`) — **INFERRED**
from the commit message, not re-measured.

## Gotchas an agent will hit

1. **`_my_env.sh` is append-only shared state.** Every script `source`s it and two of them
   `>>` to it. Re-running `osc-setup.sh` appends a *second* `OSC_*` block; teardown never
   prunes it. Treat "last definition wins" as the semantics, and never assume it is clean.
2. **`instanciate_image_outscale.sh` silently overrides `_my_env.sh`.** It sources the env
   on line 4, then *re-assigns* `MACHINE_TYPE`, `FLEX_FLAG`, `FLEX_SIZE_GB`, `VOLUME_TYPE`
   on lines 11-15. Your `_my_env.sh` values for those are **ignored** (VERIFIED by execution).
3. **The admin password is on the wire and in the logs.** It is a positional argv to a
   `sudo` command on each node → lands in that node's `auth.log`/journal, and is echoed to
   the operator's stdout twice. Do not add more copies; see F-05.
4. **`set -euo pipefail` + parallel subshells.** `cluster_instanciate.sh` backgrounds nodes
   2..N and `wait`s each pid; any node failing aborts the orchestrator mid-cluster, leaving
   billable VMs behind. There is no cleanup trap.
5. **All `ssh`/`scp` use `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`.**
6. **AZ round-robin is hardcoded to exactly 3** (`rr_idx()` = `((i-1)%3)+1`), even for N=35.
7. **`README.md` is stale** — it still documents the pre-split monorepo (AWS scripts, Packer
   templates, `my_instanciate_outscale.sh`). 8 cited paths do not exist and the real entry
   point is never named. Do not trust it; trust `docs/`.
8. `10.0.0.0/8` (not `/16`) is used for the "internal" SG rules.
9. **`tear_down_outscale.sh` destroys the Net, which is shared with the Build repo.** It also
   deletes *every* VM in that Net and reports success unconditionally. To recycle a cluster use
   `osc/destroy_cluster.sh` instead.
10. **Node IPs change on every deploy, and the DNS delegation must be re-pointed** — the script
   prints records to *add* but never the stale ones to *remove* (F-42). A shrink from N to M
   nodes leaves N−M dead nameservers that break the whole zone.

## Conventions

- Work on a branch off `main`; Conventional Commits; never commit `_my_env.sh`.
- `shellcheck` clean-or-explained for any script you touch.
- Keep scripts bash-portable (the interactive shell is zsh, the scripts are bash).
