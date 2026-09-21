# Architecture — OSC-RedisEnterprisePacker-Run

> Reconstructed from code on 2026-09-21. Every statement is **VERIFIED** (read in the
> code / executed) or **INFERRED** (a reasoned guess — confirm with the author).

## 1. Scope of this repo

**VERIFIED.** This repo is the **run/deploy half** of a two-repo system:

| Repo | Role |
|---|---|
| `OSC-RedisEnterprisePacker-Build` | Packer build of the Redis Enterprise OMI (machine image). Owned/run by Redis. |
| `OSC-RedisEnterprisePacker-Run` (**this**) | Consumes that OMI: provisions Outscale network, boots N VMs, forms a Redis Enterprise cluster. Run by the Outscale customer. |

**VERIFIED (git history).** Until commit `42cf32d` (2025-09-29) the two halves lived in
one repo, which also had a full AWS target (`aws/`) and the Packer templates
(`packer/*.pkr.hcl`). That commit ("Cleanup to keep run on Outscale") deleted
`aws/`, `packer/` and `build_scripts/` from here. **The README was never updated for
that split** — see `docs/tasks.md` R-05.

## 2. Components

```
                    operator workstation (or a bastion VM inside Outscale)
                    ├── _my_env.sh            ← single mutable state file (gitignored)
                    ├── oapi-cli  ─────────────────────────┐
                    └── ssh/scp ────────────────┐          │
                                                │          │  Outscale API (OAPI)
   osc/osc-setup.sh ────────────────────────────┼──────────┤  CreateNet / Subnet /
     Net 10.0.0.0/16, InternetService,          │          │  RouteTable / SecurityGroup
     RouteTable + 0.0.0.0/0, 3 Subnets          │          │
     (10.0.10|20|30.0/24 in <region>a|b|c),     │          │
     1 SecurityGroup  ──► appends OSC_* to _my_env.sh      │
                                                │          │
   osc/cluster_instanciate.sh  (ORCHESTRATOR)   │          │
     │                                          │          │
     ├─ node 1 (sequential)                     │          │
     │    └─ osc/instanciate_image_outscale.sh ─┼──────────┤  CreateVms(OMI) + 2x io1 BSU
     │         waits VmState=running, waits SSH │          │  CreateTags
     │         appends OUTSCALE_INSTANCE_PUBLIC_IP_1       │
     │    └─ scp+ssh ─► image_scripts/create-or-join-redis-cluster.sh  mode=init
     │                    └─ rladmin cluster create
     ├─ sleep 30
     └─ nodes 2..N (all in parallel, `--parallel N` caps it)
          └─ same instanciate script, then …cluster.sh mode=join <master_ip>
                    └─ rladmin cluster join

   stdout ─► BIND-style A + NS records the operator pastes into their DNS zone
   osc/tear_down_outscale.sh  ─► DeleteVms, then unwind RTB/SG/IS/Subnets/Net
   osc/connect_to_my_instance.sh <idx> ─► ssh to node <idx>
```

## 3. Control flow, step by step

**VERIFIED** by reading `osc/cluster_instanciate.sh`:

1. `SECONDS=0`, source `_my_env.sh`, parse `--nodes` (default 3) / `--parallel` (default 0 = unlimited).
2. Validate: `--nodes` must be an **odd integer, 3 ≤ N ≤ 35**; `OUTSCALE_AMI_ID` must be set.
   *(Verified by execution: `--nodes 4` → `Error: --nodes must be odd and 3 ≤ N ≤ 35. Got: 4`, exit 1.)*
3. If `FLEX_FLAG=flex`, build `FLE_CMD` — a remote snippet that writes
   `/etc/udev/rules.d/99-rotational-fix.rules` forcing `queue/rotational=0` on `sd*`/`vd*`
   (Outscale io1 volumes are misreported as rotational), reloads udev, then runs
   `/opt/redislabs/sbin/prepare_flash.sh -y`.
4. Node 1 → `launch_node 1` → `configure_node … init`, then a **fixed `sleep 30`**.
5. Nodes 2..N → each in a background subshell: `sleep $i` stagger, launch, re-`source _my_env.sh`
   to pick up its own IP, `configure_node … join $ip_master`, append `$i $ip` to a tempfile.
6. `wait` on every pid, rebuild `NODE_IPS` from the tempfile.
7. Print the DNS zone block: `nsN.<CLUSTER_DNS> A <ip>` for each node, `<CLUSTER_DNS> A <ip>`
   for each node, and `<CLUSTER_DNS> NS nsN.<CLUSTER_DNS>.` for each node — i.e. **every node
   is an authoritative NS for the cluster zone** (Redis Enterprise runs its own DNS).
8. Print the access URL + credentials, and the elapsed time.

**AZ placement (VERIFIED):** `rr_idx()` = `((i-1) % 3) + 1` — strict round-robin over
exactly 3 subnets/AZs, regardless of N.

## 4. State model — `_my_env.sh`

**VERIFIED.** There is no database and no terraform state. `_my_env.sh` (gitignored,
copied from `_my_env.template.sh`) is the **only** state, and it is **append-only**:

| Written by | Keys |
|---|---|
| operator, by hand | `OWNER` `OUTSCALE_REGION` `OUTSCALE_SSH_KEY` `REDIS_LOGIN` `REDIS_PWD` `OUTSCALE_CLUSTER_DNS` `FLEX_FLAG` `FLEX_SIZE_GB` `FLEX_IOPS` `MACHINE_TYPE` `OUTSCALE_AMI_ID` |
| `osc-setup.sh` (`>>`) | `OSC_NET_ID` `OSC_IGW_ID` `OSC_RTB_ID` `OSC_SG_ID` `OSC_SUBNET1..3` `OSC_AZ1..3` |
| `instanciate_image_outscale.sh` (`>>`) | `OUTSCALE_INSTANCE_PUBLIC_IP_<n>=<ip> #<vm-id>` |

Consequences (all **VERIFIED** by reading the `>>` redirections): re-running `osc-setup.sh`
appends a **second** block of `OSC_*` (last definition wins, first Net is orphaned and keeps
billing); `tear_down_outscale.sh` never prunes the file, so stale IDs/IPs persist into the
next run. The README papers over this with a manual "remove the generated values" note.

## 5. Network & exposure

**VERIFIED** from `osc/osc-setup.sh`:

- Net `10.0.0.0/16`; subnets `10.0.10.0/24`, `10.0.20.0/24`, `10.0.30.0/24` in
  `${REGION}a|b|c`; `MapPublicIpOnLaunch=true` on all three → **every node gets a public IP**.
- Default route `0.0.0.0/0` → Internet Service.
- One security group, inbound from **`0.0.0.0/0`**: tcp 22, 8001, 8070, 8080, 3346, 8443,
  9443, tcp **10000-10049**, tcp **10051-19999**, udp 53, udp 5353.
- Inbound from `10.0.0.0/8` (note: **/8**, not the Net's /16): the Redis Enterprise
  intra-cluster set — 1968, 3333-3345, 3346, 3347-3349, 3350-3354, 3355, 8001, 8002, 8004, 8006,
  8071, 8443, 9080-9082, 9091, 9125, 9443, 10000-10049, 10051-19999, 20000-29999, 36379,
  udp 53, udp 5353.

There is **no load balancer** and **no private-only path** in this repo (**VERIFIED**: no
`CreateLoadBalancer` call anywhere) — client reachability is public IP + the cluster's own
DNS. See `docs/tasks.md` F-02 / F-10 / F-26.

## 6. Contract with the OMI (the image)

**VERIFIED against `OSC-RedisEnterprisePacker-Build@854574e`** (read on 2026-09-21). The
build repo also carries `docs/handover-run-findings.md` — a 30-item audit written *for this
repo*; it is the source of the `F-*`/`R-*` IDs used in `../tasks.md`.

### What the image provides

| Item | Value |
|---|---|
| Base OS | **Ubuntu 22.04 LTS (Jammy)**, x86_64, resolved to the newest official base OMI at build time |
| Redis Enterprise | **8.2.0-78**, installed into `/opt/redislabs`, GPG fingerprint pinned, `rlcheck` must report `ALL TESTS PASSED` |
| SSH user | **`outscale`** (key-only: `PasswordAuthentication no`, `PermitRootLogin no`) |
| Root volume | 30 GB `gp2`, ~2.6 GB used |
| Build region | `eu-west-2` only — **the OMI is not replicated to other regions** |
| Current OMI | `ami-89fe7cac` (built 2026-09-19) |
| Swap | **off permanently** (`swapoff -a` + `systemctl mask swap.target`) — a Redis Enterprise requirement |
| DNS | `DNSStubListener=no`, `resolv.conf` → `/run/systemd/resolve/resolv.conf` ⇒ **UDP 53/5353 left free for Redis Enterprise's own DNS responder** |
| Clock | `systemd-timesyncd`, asserted `NTP=yes` at build time (`ntp=no` in the RE answer file) |
| Hardened away | `snapd`, `apport`, `unattended-upgrades` purged ⇒ **no automatic security updates**; AppArmor disabled; `auditd` not installed |
| De-identified | SSH host keys removed, `machine-id` truncated, `cloud-init clean`, logs + `authorized_keys` wiped — **verified**: two VMs from one OMI had distinct host-key fingerprints |
| `prepare_flash.sh` | ships with the Redis Enterprise package at `/opt/redislabs/sbin/`; the build deliberately prepares **nothing** for flash — that is this repo's job |
| Licence | **out of scope of the image** — the customer supplies their own tarball and licence |

### ⚠️ The image now ships an ACTIVE host firewall

This is the most important change since this repo was last touched, and **this repo does not
yet account for it**:

- `ufw` is **enabled and enforcing** on first boot. The build refuses to publish an image
  where `ufw status` is not `active` or where nothing allows `22/tcp`.
- The rules baked in are **port-scope only** — `CLIENT_CIDR`, `OPERATOR_CIDR` both default
  to `any`; `CLUSTER_CIDR` defaults to RFC1918 (`10/8`, `172.16/12`, `192.168/16`).
  Cleartext REST `8080` is **denied** unless explicitly allowed.
- The image exposes a re-scoping tool the run side is *expected* to call:
  ```sh
  /usr/local/sbin/redis-enterprise-firewall \
      --cluster-cidr 10.0.0.0/16 \
      --client-cidr  10.20.0.0/16 \
      --operator-cidr 203.0.113.4/32
  # also: --allow-insecure-rest  --scope-ssh  --dry-run
  ```
  **`cluster_instanciate.sh` never invokes it** → `../tasks.md` F-41.
- The image's `CLUSTER_TCP` set includes **8444, 3357 and 8000**, which `osc-setup.sh`'s
  security group does **not** open → `../tasks.md` F-18.
- Build's own `T-19` is *"UFW rule set shipped, cluster validation owed"*, and the stated
  gate is a real `cluster_instanciate.sh --nodes 3`. **So there are now two firewalls in
  series (Outscale SG + host UFW) and the combination has never been exercised on a formed
  cluster.** If a cluster fails to form, the first diagnostic is
  `journalctl -k | grep 'UFW BLOCK'` on each node. → `../tasks.md` F-41

### What this repo must supply at run time (VERIFIED)

| Assumption | Where it is relied on |
|---|---|
| SSH as `outscale` | `instanciate_image_outscale.sh:200`, `cluster_instanciate.sh:85,87`, `connect_to_my_instance.sh:19` |
| `/opt/redislabs/bin/rladmin` | `image_scripts/create-or-join-redis-cluster.sh:49,72` |
| `/opt/redislabs/sbin/prepare_flash.sh` | `cluster_instanciate.sh:65` |
| Cluster-create arguments (nothing is baked in) | `create-or-join-redis-cluster.sh:72-79` |
| Hostname / `/etc/hosts` (image sets no hostname) | `create-or-join-redis-cluster.sh:19-25` |
| The node's primary NIC is in `10.0.0.0/8` | `create-or-join-redis-cluster.sh:19` greps `'^10\.'` — works today **only** because `osc-setup.sh` hardcodes `10.0.0.0/16` → F-24 |
| Flash volumes + `rotational=0` + `prepare_flash.sh` before `flash_enabled` | `cluster_instanciate.sh:51-67` |
| Each node published as an `NS` for the cluster FQDN | `cluster_instanciate.sh:167-179` (manual step) |
| Re-scoping the host firewall to real CIDRs | **not done** → F-41 |

**Un-bootstrapped state check** (useful when debugging a stuck node): `rladmin status`
returns `invalid token 'status'` on a fresh node; use
`curl -sk https://localhost:9443/v1/bootstrap` and look for `state: idle`.

`image_scripts/create-or-join-redis-cluster.sh` is `scp`'d at run time rather than baked
into the image, despite the directory name. Build has **deleted** its copy (its `R-02`), so
this repo is now the **sole owner** of that file. → F-39

### Shared-file ownership (VERIFIED, and it has changed)

`osc/osc-setup.sh` and `osc/tear_down_outscale.sh` exist in **both** repos. Build's earlier
plan to delete its copies was **withdrawn** (the build legitimately needs its own network);
instead Build added a `diff`-based drift guard (`scripts/lint.sh` + `scripts/shared-drift.baseline`).
Live state: **dual ownership with an automated guard**, and Build's copies are now *ahead* —
they gained `build_scripts/lib/env_file.sh` (sentinel-delimited, rewritten-in-place env
blocks) and a `sleep 15` in the teardown. Porting those into this repo is F-20 / F-27.

## 7. What is deliberately absent

**VERIFIED** (nothing in the tree provides these): no tests, no CI (`.github/` absent —
note Build *does* have `.github/workflows/ci.yml`), no linter gate, no licence
installation (`README.md:271-272` — "TODO: Ajout de la license", and per Build's PRD the
licence is the customer's to supply), no `CLAUDE.md` before this pass, no idempotency or
locking, no load balancer, no private/bastion topology, and no AWS target any more.
