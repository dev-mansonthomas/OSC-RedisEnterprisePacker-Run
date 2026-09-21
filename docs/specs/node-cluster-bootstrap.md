# Spec — On-node bootstrap (`image_scripts/create-or-join-redis-cluster.sh`)

Runs **on each Redis node**, as root via `sudo`, pushed by `configure_node()`.

## Inputs — 8 positional arguments
| # | Name | Required | Notes |
|---|---|---|---|
| 1 | `cluster_dns` | yes | becomes the cluster `name` |
| 2 | `RS_admin` | yes | Redis Enterprise admin login |
| 3 | `RS_password` | yes | **cleartext in argv** → `F-05` |
| 4 | `mode` | yes | `init` \| `join`; anything else prints usage, exit 1 |
| 5 | `node_external_addr` | yes | the node's public IP → `external_addr` |
| 6 | `zone` | yes | subregion → `rack_id` |
| 7 | `node_id` | yes | only used in the `/etc/hosts` line |
| 8 | `master_ip` | only if `mode=join` | validated |

## Behaviour (VERIFIED)
1. Derive `internal_ip` = first non-loopback IPv4 **matching `^10\.`**; build
   `hostname_fmt=ip-<dashed-ip>`; **append** `"<ip> <hostname_fmt> redis-node-<id>"` to `/etc/hosts`.
   (`hostnamectl set-hostname` is present but commented out.)
2. Echo every parameter name and value — **including `RS_password`** — then
   `exec &> >(tee -a /var/log/redis-enterprise-init.log)`.
3. `mode=init` → `rladmin cluster create name … username … password … external_addr …
   flash_enabled rack_aware rack_id …`; non-zero ⇒ exit 1.
4. `mode=join` → `join_master()`: up to **10 attempts**, `rladmin cluster join … nodes
   <master_ip> external_addr … flash_enabled rack_id …`, `sleep 30` between attempts
   (≈4.5 min of retry budget). Failure ⇒ exit 1.

## Edge cases
- **`^10\.` is hardcoded.** A customer-supplied Net in `172.16/12` or `192.168/16` yields an
  empty `internal_ip`, a malformed `/etc/hosts` line, and no hard error. Directly blocks the
  "customer brings their own network" requirement. → `F-24`
- If the node has **several** `10.*` addresses, `internal_ip` becomes a multi-line string and
  the `/etc/hosts` line is corrupt. → `F-24`
- `/etc/hosts` is appended to on **every** invocation → duplicate entries on re-run. → `F-34`
- The parameter echo happens **before** the `tee` redirection, so the password goes to the
  ssh channel (operator's terminal), not the node's logfile. The `sudo` invocation itself,
  however, *is* logged with full argv by the OS. → `F-05`
- `rack_aware` is set only on `create`; joins pass `rack_id` alone. Consistent with Redis
  Enterprise semantics (**INFERRED** — cluster-level flag set once).
- `flash_enabled` is passed unconditionally, even when `FLEX_FLAG` is empty and no flash
  volumes were attached. **INFERRED** risk: `rladmin` may reject it on a node with no
  prepared flash. → `F-35`
- No license installation step. → `F-40`
- The script is `scp`'d into the operator-writable `/home/outscale/`, `chmod 700`'d, then
  executed by root — a writable-path-to-root window. Baking it into the OMI removes it. → `F-28`

## Acceptance criteria (as implemented)
- Exit 0 ⇒ `rladmin` reported success and `Initialisation terminée.` is in
  `/var/log/redis-enterprise-init.log`.
