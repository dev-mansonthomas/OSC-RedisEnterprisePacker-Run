# Spec — Single VM instantiation (`osc/instanciate_image_outscale.sh`)

## Purpose
Boot exactly one Redis Enterprise node from the OMI and return only once it is
**actually reachable over SSH**.

## Inputs
| Kind | Name | Required | Notes |
|---|---|---|---|
| argv | `--node-num <n>` | **yes** | used for the `Name` tag `redis-node-<n>` and the env key |
| argv | `--subnet <1\|2\|3>` | **yes** | selects `OSC_SUBNET<idx>` **and** `OSC_AZ<idx>` |
| argv | `-h\|--help` | no | prints usage, exit 0 |
| `_my_env.sh` | `OUTSCALE_AMI_ID` | yes | hard-fails if empty |
| `_my_env.sh` | `OSC_SG_ID`, `OSC_SUBNET<idx>` | yes | hard-fail if empty |
| `_my_env.sh` | `OUTSCALE_SSH_KEY` | yes | private key used for the readiness probe |
| env | `MAX_WAIT` | no | `600` s SSH-readiness timeout |
| env | `SLEEP_STEP` | no | `5` s between probes |
| env | `FLEX_IOPS` | no | `1000` |

**Hardcoded, NOT read from `_my_env.sh` (defect `F-04`):** `MACHINE_TYPE=tinav5.c2r4p3`,
`FLEX_FLAG=flex`, `FLEX_SIZE_GB=40`, `VOLUME_TYPE=io1`, and `--KeypairName
"outscale-tmanson-keypair"`. Lines 11-15 re-assign these *after* line 4 sources the env.

## Outputs
- Console: a parameter banner, the raw `CreateVms` JSON, the instance ID, the public IP,
  a ready-to-paste `ssh` line, and readiness progress.
- **Appended** to `../_my_env.sh`: `OUTSCALE_INSTANCE_PUBLIC_IP_<n>=<ip> #<vm-id>`.

## Behaviour (VERIFIED)
1. Parse + validate argv.
2. If flex: build a 2-entry `BlockDeviceMappings` (`/dev/sdf`, `/dev/sdg`) via `jq -nc`,
   `io1`, `VolumeSize=$FLEX_SIZE_GB`, `Iops=$FLEX_IOPS`, `DeleteOnVmDeletion=true`.
3. `CreateVms` with the OMI, VM type, keypair, subnet, `Placement.SubregionName=$AZ`, SG, BDM.
4. Poll `ReadVmsState` every 3 s until `VmState == running`.
5. `CreateTags Name=redis-node-<n>`.
6. **SSH readiness**: loop — TCP probe via `/dev/tcp/$IP/22`, then a real
   `ssh -o BatchMode=yes … true` handshake. Break on success; exit 1 after `MAX_WAIT`.
   *(Added in `10d933d` to replace a flaky fixed sleep.)*
7. Append the IP line.

## Edge cases
- **Omitting `--node-num` crashes instead of showing usage** (VERIFIED by execution):
  `SUBNET_IDX=""` is pre-initialised but `NODE_IDX` is not, so `set -u` fires first:
  `line 58: NODE_IDX: unbound variable`. → `F-16`
- `--subnet` is not range-checked; `--subnet 4` yields `OSC_SUBNET4: unbound variable`.
- `io1` requires `Iops ≤ 50 × VolumeSize`. The default 1000 IOPS is legal only at
  ≥ 20 GiB; a smaller `FLEX_SIZE_GB` produces an opaque API error. No validation. → `F-31`
- The step-4 poll has **no timeout** — a VM stuck in `pending` loops forever.
- If the script fails after step 3, the VM exists but its IP is never recorded → orphan.
- Public IP comes from `MapPublicIpOnLaunch`; it is read from the `CreateVms` response, so
  it is assumed present immediately (**INFERRED**: true on Outscale, observed in the README's
  sample output).

## Acceptance criteria (as implemented)
- Exit 0 ⇒ VM is `running`, tagged, SSH-reachable with `OUTSCALE_SSH_KEY` as `outscale`, and
  its public IP is in `_my_env.sh`.
