# Spec — Network provisioning (`osc/osc-setup.sh`)

## Purpose
Create the Outscale network substrate a Redis Enterprise cluster needs, and record the
resulting IDs so the other scripts can find them.

## Inputs
| Source | Name | Required | Observed default |
|---|---|---|---|
| `_my_env.sh` | `OWNER` | yes | — (used for tag + `${OWNER}-net` / `${OWNER}-sg` names) |
| `_my_env.sh` | `OUTSCALE_REGION` | no | `eu-west-2` (`${OUTSCALE_REGION:-eu-west-2}`) |
| `~/.osc/config.json` | profile `default` | yes | hardcoded `OAPI_PROFILE="default"` |
| argv | — | — | **takes no arguments** (usage comment says `./osc-setup.sh` with none) |

## Outputs
1. Console: an `===== OUTSCALE Resource Summary =====` block.
2. **Appended** (`>>`) to `../_my_env.sh`: `OSC_NET_ID` `OSC_IGW_ID` `OSC_RTB_ID` `OSC_SG_ID`
   `OSC_SUBNET1..3` `OSC_AZ1..3`.

## Behaviour (VERIFIED, in order)
1. `CreateNet --IpRange 10.0.0.0/16`, then `CreateTags` with `Owner=$OWNER`, `Name=${OWNER}-net`.
2. `CreateInternetService` + `LinkInternetService`.
3. `CreateRouteTable` + `CreateRoute 0.0.0.0/0 → $IGW_ID`.
4. Loop `i` in 1..3: `CreateSubnet` `10.0.$((i*10)).0/24` in `${REGION}{a,b,c}`,
   `LinkRouteTable`, `UpdateSubnet --MapPublicIpOnLaunch true`.
5. `CreateSecurityGroup ${OWNER}-sg`, then rules (see `../architecture/overview.md` §5).
6. Append the env block.

## Edge cases / observed limits
- **Not idempotent.** No pre-flight `ReadNets`; a second run creates a whole second stack and
  appends a second `OSC_*` block. The earlier Net is orphaned and keeps billing. → `F-20`
- **Not transactional.** `set -euo pipefail` means a failure at, say, step 5 leaves a Net,
  IS, RTB and 3 subnets created but **no env block written at all** (the append is last),
  so `tear_down_outscale.sh` cannot clean up. → `F-29`
- **Hardcoded to 3 subregions** named `<region>a|b|c`. Regions that do not expose exactly
  `a`,`b`,`c` will fail at `CreateSubnet`. → `F-30` (**INFERRED** — not tested against a
  region other than `eu-west-2`)
- **Cannot consume customer-supplied resources.** There is no "use my existing Net/Subnet/SG"
  path, although that is a stated product requirement. → `F-26`
- `pause()` is a no-op (its `read` is commented out, `a7b309a`), so the script never stops
  for confirmation before creating billable resources.
- CIDR `10.0.0.0/16` is fixed; the SG's "internal" rules use `10.0.0.0/8`, i.e. broader
  than the Net.

## Acceptance criteria (as implemented)
- Exit 0 ⇒ 1 Net, 1 Internet Service, 1 route table with a default route, 3 public subnets in
  3 distinct subregions, 1 security group, and 10 new lines in `_my_env.sh`.
