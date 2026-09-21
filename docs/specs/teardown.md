# Spec — Teardown

Two scripts, two scopes. Pick by what you want to survive.

| Script | Deletes | Keeps |
|---|---|---|
| `osc/destroy_cluster.sh` | the VMs (and their volumes) | Net, Internet Service, route table, subnets, security group |
| `osc/tear_down_outscale.sh` | **everything** — VMs then the whole network | nothing |

---

## Part 2 — `osc/destroy_cluster.sh` (added 2026-09-21, F-45)

### Inputs
| Kind | Name | Default | Notes |
|---|---|---|---|
| `_my_env.sh` | `OSC_NET_ID` | — | required (`:?`) |
| `_my_env.sh` | `OSC_SG_ID` | — | optional; only used by the final survival check |
| argv | `-y\|--yes` | off | skip the confirmation prompt |
| argv | `--all-vms` | off | widen scope to **every** VM in the Net, not just `redis-node-<n>` |
| argv | `--keep-env` | off | leave `_my_env.sh` untouched |
| argv | `--timeout <s>` | `300` | max wait for terminal state; also `TIMEOUT` env |
| env | `OAPI_PROFILE` | `default` | passed to **every** `oapi-cli` call (F-15) |

### Behaviour
1. `set -euo pipefail` **before** sourcing the env file (F-12).
2. `ReadVms` filtered by `NetId`; select by tag `Name =~ ^redis-node-[0-9]+$` unless `--all-vms`;
   drop anything already `terminated`. Record the attached `Bsu.VolumeId`s **before** deleting.
3. Print the plan (VM id, state, public IP, name) and the volume list; prompt unless `-y`.
4. `DeleteVms`.
5. Poll `ReadVms` every 5 s until none of *those* ids is non-terminated. **On timeout: print the
   stuck VMs and exit 1** (contrast with Part 1, which loops forever and always succeeds).
6. Unless `--keep-env`: `cp -p` a `.bak`, then `grep -v '^OUTSCALE_INSTANCE_PUBLIC_IP_'` back
   into the original path — a redirect into the existing file, so inode and mode `0600` are kept.
7. `ReadVolumes` on the recorded ids; report anything not `deleting` as still billed.
8. Verify the Net and SG still exist; exit 1 if either vanished.

### Edge cases
- Zero matching VMs ⇒ says so, still prunes the env file, exits 0 (idempotent).
- A foreign VM in the same Net is **not** touched without `--all-vms` — verified against a
  fixture containing a `bastion-client` VM, whose volume was also correctly excluded.
- `--timeout` is validated as an integer.
- `shellcheck`-clean, unlike every other script in the repo.
- **Not exercised against the live API yet.**

### Acceptance criteria
- Exit 0 ⇒ every targeted VM is `terminated`, the Net and SG still exist, `_my_env.sh` holds no
  `OUTSCALE_INSTANCE_PUBLIC_IP_*`, and any surviving volume has been named.

---

## Part 1 — `osc/tear_down_outscale.sh`

## Inputs
All from `_my_env.sh`, all mandatory (`: "${VAR:?…}"`): `OSC_NET_ID` `OSC_RTB_ID` `OSC_SG_ID`
`OSC_IGW_ID` `OSC_SUBNET1..3`. Optional env `OAPI_PROFILE` (default `default`).
**Takes no arguments and asks for no confirmation.**

## Behaviour (VERIFIED) — 7 steps
1. `ReadVms --Filters {"NetIds":[…]}` → `DeleteVms`, then `wait_vms_terminated()` polls
   `ReadVmsState` every 5 s until no VM is in a state other than `terminated`.
2. `DeleteRoute 0.0.0.0/0` — `|| true`.
3. `ReadRouteTables`, **hard-fail if the response carries `.Errors`**, then
   `UnlinkRouteTable` per `LinkRouteTableId` (hard-fail on error).
4. `DeleteRouteTable` — `|| true`.
5. `DeleteSecurityGroup` — `|| true`.
6. `UnlinkInternetService` + `DeleteInternetService` — `|| true`.
7. `DeleteSubnet` ×3, then `DeleteNet` — `|| true`.

## Edge cases
- **Swallows almost every failure** (`|| true` on steps 2,4,5,6,7) and still prints
  `Teardown terminé.` with exit 0. A `DeleteNet` that fails because a dependency survived is
  reported as success, leaving billable resources. → `F-21`
- **`wait_vms_terminated` has no timeout** — a VM that will not terminate loops forever.
- **Never prunes `_my_env.sh`.** Stale `OSC_*` and `OUTSCALE_INSTANCE_PUBLIC_IP_*` lines
  survive into the next run, where they shadow or conflict with fresh values. → `F-20`
- **Only deletes what is in `_my_env.sh`.** If `osc-setup.sh` died before its append (see
  `network-provisioning.md`), teardown cannot see those resources at all. → `F-29`
- **No confirmation prompt** for a fully destructive, tenant-wide-by-NetId operation. → `F-36`
- `VM_IDS=($(…))` triggers `shellcheck` SC2207 (word-splitting); harmless for Outscale ID
  formats but non-idiomatic.
- Deletes every VM in the Net, including any the customer created there by hand. → `F-36`

## Acceptance criteria (as implemented)
- Prints `Teardown terminé.` — which today does **not** imply the resources are actually gone.
