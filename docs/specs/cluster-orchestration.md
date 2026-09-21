# Spec — Cluster orchestration (`osc/cluster_instanciate.sh`)

## Purpose
The **main entry point**. Turn an empty (but provisioned) network into a running N-node
Redis Enterprise cluster, and emit the DNS records the operator must publish.

## Inputs
| Kind | Name | Default | Constraint |
|---|---|---|---|
| argv | `--nodes <N>` | `3` | integer, **odd**, `3 ≤ N ≤ 35` (enforced) |
| argv | `--parallel <0\|N>` | `0` | `0` = unlimited concurrent nodes |
| argv | `-h\|--help` | — | prints usage, exit 0 |
| `_my_env.sh` | `OUTSCALE_AMI_ID` (or `AMI_ID`) | — | required |
| `_my_env.sh` | `OUTSCALE_CLUSTER_DNS` `REDIS_LOGIN` `REDIS_PWD` `OUTSCALE_SSH_KEY` `OSC_AZ1..3` | — | required |
| `_my_env.sh` | `FLEX_FLAG` | — | `flex` enables the flash prep block |

## Outputs
- A formed Redis Enterprise cluster named `$OUTSCALE_CLUSTER_DNS`.
- Console: a BIND zone fragment — for each node `nsN.<zone>. 10800 IN A <ip>`, then
  `<zone>. 10800 IN A <ip>` per node, then `<zone>. 10800 IN NS nsN.<zone>.` per node.
- Console: the access URL **with the admin username and password in cleartext**
  (`cluster_instanciate.sh:182`). → `F-05`
- Console: elapsed time from `$SECONDS`.
- Side effects in `_my_env.sh` via the per-node instantiation script.

## Behaviour (VERIFIED)
1. Validate (see `../architecture/overview.md` §3 for the full step list).
2. Node 1: `launch_node 1` → re-`source _my_env.sh` → `configure_node <ip> <AZ1> init 1`
   → **fixed `sleep 30`**.
3. Nodes 2..N: one background subshell each (`wait_slot` caps concurrency when
   `--parallel > 0`), staggered by `sleep $i`; each launches its VM, re-sources the env for
   its own IP, then `configure_node <ip> <AZ> join <i> <ip_master>`.
4. `wait` every pid; rebuild `NODE_IPS` from a `mktemp` file.
5. Print the DNS block, the access line, and the duration.

`configure_node()` = `scp` `../image_scripts/create-or-join-redis-cluster.sh` to
`/home/outscale/`, then one `ssh` with an **unquoted** heredoc that runs `$FLE_CMD`
(or `true`), `chmod 700`, then `sudo …/create-or-join-redis-cluster.sh <8 positional args>`.

## Edge cases / observed limits
- **Fixed `sleep 30`** instead of polling the cluster for readiness — the same anti-pattern
  that was already removed for SSH. Too short ⇒ every join burns its retry budget; too long
  ⇒ wasted minutes. → `F-14`
- **No cleanup on failure.** With `set -e`, a failed `wait` aborts the orchestrator; already-
  created VMs are left running and billable, and the cluster is half-formed. No `trap`. → `F-32`
- **Concurrent `>>` and `source` on `_my_env.sh`.** N-1 subshells append to the file while
  others source it. Short `O_APPEND` writes are atomic in practice, so this is *probably*
  safe — but it is unsynchronised by construction. (**INFERRED**, not stress-tested.) → `F-01`
- `--parallel 0` (the default) fans out up to 34 simultaneous `oapi-cli` + `ssh` streams;
  Outscale API throttling is not handled (no retry/backoff on `CreateVms`). → `F-33`
- AZ round-robin is fixed at 3 (`rr_idx`), so N=35 puts 12/12/11 nodes in 3 AZs.
- `--nodes` is validated, but nothing checks the account's VM/IP quota first.
- `FLE_CMD` is built with a *quoted* heredoc and then interpolated into an *unquoted* one.
  Verified experimentally that bash does **not** re-expand the substituted text, so the
  embedded `$(basename "$d")` and `$d` correctly reach the remote shell intact — this is
  **not** a bug, but it is fragile enough to deserve the `shellcheck` SC2087 note.

## Acceptance criteria (as implemented)
- Exit 0 ⇒ N nodes joined, UI answers on `https://$OUTSCALE_CLUSTER_DNS:8443`, and the DNS
  block has N A-records + N NS-records.
