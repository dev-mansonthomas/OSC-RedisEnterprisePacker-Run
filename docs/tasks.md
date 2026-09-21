# Task backlog — OSC-RedisEnterprisePacker-Run

Reconstructed 2026-09-21 from code, git history, `shellcheck`, executed probes, and
`OSC-RedisEnterprisePacker-Build@854574e`'s `docs/handover-run-findings.md`.

**The 2026-09-21 reconstruction pass was read-only.** Four items were fixed afterwards, on
request, because they are the *instrumentation* for the F-41 build-validation loop rather than
run-repo improvements: **F-04**, **F-09** (+ **F-11**, **F-16** in passing), then **F-18**.
Each is marked ✅ inline with the evidence. Everything else is untouched.

**First real deploy: 2026-09-21** (`debug/f41-20260921T154911.log`). **F-41 validated** — the
image's active `ufw` does not block cluster formation. It also exposed **F-25 as 🔴** and produced
two new findings, **F-42** and **F-43**, both about the DNS hand-off. Post-deploy database
creation then surfaced **F-44** (default node size too small to host a database).

## How to read this

- **IDs are the canonical `F-*`/`R-*` register** from the Build repo's parked handover
  document. They are reused verbatim so the two repos stay cross-referenceable.
  IDs **F-28…F-41** and **R-05, R-07** are **new in this pass** (found here, not in that
  register) and are marked **NEW**.
- **Severity:** 🔴 blocks a customer delivery · 🟠 real bug or real risk · 🟡 robustness · ⚪ hygiene
- **Evidence:** **VERIFIED** = read in the code, or reproduced by running something (the
  command is given). **INFERRED** = reasoned from patterns, not proven.

## Status of the whole repo, measured

| Gate | Result |
|---|---|
| `bash -n` on all 6 scripts | **PASS** (VERIFIED 2026-09-21) |
| `shellcheck -f gcc osc/*.sh image_scripts/*.sh` | **exits 1** — 12 findings: 7× `SC1091` (benign), **3×** `SC2086`, 1× `SC2087`, 1× `SC2207` (VERIFIED). The third `SC2086` is new: the F-09 verification block reuses the file's existing deliberate-word-splitting `ssh $SSH_OPTS` idiom. Fix all three together under R-06. |
| Tests | **none exist** |
| CI | **none exists** (`.github/` absent) |
| Real deploy | **PASSED 2026-09-21** — 3 nodes, 6 min 01 s, `ami-89fe7cac`. Cluster formed, health checks clean (after the operator's SG port fix), UI + REST + cluster DNS up, a <5 GB RAM database created, and **Redis Insight connected from an external laptop and loaded data**. Log: `debug/f41-20260921T154911.log` |

---

## P0 — do first

### F-41 ✅ **VALIDATED 2026-09-21 — the image's active `ufw` does NOT block cluster formation**
The OMI boots with `ufw` enabled and enforcing, and exposes
`/usr/local/sbin/redis-enterprise-firewall --cluster-cidr … --client-cidr … --operator-cidr …`
which this repo never calls. The two firewalls in series (Outscale SG + host `ufw`) had never
been exercised together.
*Result:* **VERIFIED by a real deploy** — `./cluster_instanciate.sh --nodes 3` against
`ami-89fe7cac`, log `debug/f41-20260921T154911.log`:
`Cluster créé avec succès`, two × `Rejoint le cluster avec succès`, **zero `Master non prêt`
retries**, `OK : le cluster déclare 3 noeud(s)`, 6 min 01 s. The admin UI answers **HTTP 200
on 8443 on all three nodes** when reached by public IP, and all three serve the zone's `SOA`
on udp/53. ⇒ **Build's `T-19` is discharged for cluster formation + UI + cluster DNS.**
*Caveat:* the SG had the three F-18 ports added to it live just before this run, so the result
validates *SG-aligned-with-image*, not the shipped SG. The re-scoping call
(`redis-enterprise-firewall` with real CIDRs) is still **not** wired in — that stays open as a
P2 hardening task, no longer a blocker.
*Client data path — VERIFIED 2026-09-21:* the operator connected **Redis Insight from an
external laptop, over the internet**, to a database on a `10000-19999` port and **loaded data
successfully**. That exercises the full chain end to end: Outscale SG (`0.0.0.0/0` on the DB
range) → the image's `ufw` (`CLIENT_TCP 10000:19999`, `CLIENT_CIDR=any`) → the Redis Enterprise
proxy → the shard → a write. ⇒ **F-41 is fully validated; Build's `T-19` is discharged.**
*Still not exercised:* the non-flex path (`FLEX_FLAG=""`, F-35); Auto Tiering at **database**
level (cluster-level only so far, ADR 0007); and the whole `production` topology of ADR 0009 —
everything validated here is the **`eval`** topology, i.e. public exposure with
`CLIENT_CIDR=any`.


### F-18 ✅ **FIXED 2026-09-21 (script)** — live SG patched separately by the operator
`8444` (web proxy ↔ `cnm_http`/`cm`), `3357` (internal communication) and `8000` (internal
metrics) were in the image's `CLUSTER_TCP` but absent from `osc-setup.sh`'s internal rules,
making the **security group strictly more restrictive than the image's own `ufw`** on those
ports — so a cluster failing to form would have implicated the image instead of the SG.
*Evidence (before):* **VERIFIED on the live security group** `sg-0bc7642e` —
`ReadSecurityGroups` returned 28 distinct rules with no `8444`, `3357` or `8000`.
*Implemented:* added to the internal `spec` loop, **plus `8070`**, which the image's
`CLUSTER_TCP` lists but the script only opened externally. The internal port set is now
**byte-for-byte the same set** as the image's `CLUSTER_TCP` — verified programmatically,
27/27 entries, `diff` clean.
*Operator action (done, outside this repo):* the three missing rules were added to the live
`sg-0bc7642e` with source `10.0.0.0/8` via `CreateSecurityGroupRule`, and confirmed present.
Note the live SG has `8070` only via its `0.0.0.0/0` rule, which is sufficient for the test.
*Where:* `osc/osc-setup.sh:168-180`
*⚠️ Drift:* this file is dual-owned (F-22). Diff against Build's copy went from **50 to 62**
changed lines, so **Build's drift guard (`scripts/lint.sh` + `scripts/shared-drift.baseline`)
will now fail.** Not fixed from here — modifying the Build repo needs a separate decision.


### F-06 🔴 A weak default admin password ships in git
`REDIS_PWD` carries a weak 9-character default in the tracked template
(`_my_env.template.sh:7`), documented twice in the old README, and printed
in the success banner, and was still in use unchanged at the first real deploy.
*Evidence:* VERIFIED — `_my_env.template.sh:7`; `README.md:124,141,226`; confirmed present in the live `_my_env.sh`.
*Action:* ship `REDIS_PWD=` empty; fail fast with a clear message; require ≥16 chars; suggest
`openssl rand -base64 24`; never print it.

### F-05 🔴 The admin password has four distinct exposure points
1. `cluster_instanciate.sh:87` uses an **unquoted** `<<EOF`, so `$RS_password` is expanded
   client-side into the command stream (`shellcheck SC2087`).
2. It arrives as `argv[3]` of a `sudo` call on the node — readable in `ps aux` / `/proc/*/cmdline`,
   **and written to the node's auth log by `sudo` itself**.
3. `create-or-join-redis-cluster.sh:28-34` echoes every parameter *including the password*.
4. `cluster_instanciate.sh:182` prints it to the operator's terminal.
*Evidence:* **VERIFIED by execution.** Replaying the parameter loop verbatim printed
`RS_password=S3cr3t-P@ss`. And `sudo -n /bin/true "PASSWORD-CANARY-abc123"` produced this
journal line on the test host:
```
COMMAND=/bin/true PASSWORD-CANARY-abc123
```
⇒ the Redis Enterprise admin password lands in cleartext in each node's `auth.log`/journal.
*Action:* `scp` the secret as an `0600` file, switch to a quoted `<<'EOF'` heredoc, read it
from that file on the node; drop `RS_password` from the echo loop; `chmod 600` the log; print
only URL + username in the banner.

### F-02 🔴 The exposure decision is not expressible, and the default is full internet exposure
The **port list itself is correct and required**. The defect is that every external rule
hardcodes source `0.0.0.0/0`, so a customer who does not hand-edit the script gets the admin
UI (8443), the REST API (9443/3346) and every database port (10000-19999) on the public
internet. Prior audit: *"For a SecNumCloud deployment the answer is very likely 'no public
exposure at all'."*
*Evidence:* VERIFIED — `osc/osc-setup.sh:132-199`; exposed to `0.0.0.0/0`: tcp 22, 8001,
8070, 8080, 3346, 8443, 9443, 10000-10049, 10051-19999, udp 53, udp 5353.
*Action:* add `OPERATOR_CIDR` (SSH + UI + REST) and `CLIENT_CIDR` (database + discovery + DNS)
to the template, **defaulting to the Net CIDR `10.0.0.0/16`**; refuse to run with `0.0.0.0/0`
unless `--allow-public`; document the bastion/VPN/peering pattern as recommended. Keep it
consistent with the image's `redis-enterprise-firewall` flag names (F-41).

### F-03 🟠 The cleartext REST API port 8080 is opened, and is optional
Redis Enterprise serves REST on `9443` (TLS) *and* `8080` (cleartext); `9443` is already in
the rule set. The image's firewall **denies** 8080 unless `--allow-insecure-rest` — so the
SG and the host firewall already disagree. *"Cleartext admin traffic fails a SecNumCloud
review regardless of source CIDR."*
*Evidence:* VERIFIED — `osc/osc-setup.sh:143`.

### F-01 🔴 Race on `_my_env.sh` during the parallel node phase
Nodes 2..N run as background subshells; each calls `instanciate_image_outscale.sh`, which
**appends** `OUTSCALE_INSTANCE_PUBLIC_IP_<n>` (l.220); each subshell then **re-`source`s that
same file** (l.139) while siblings are still writing. No locking. `sleep "$i"` narrows the
window but does not close it; at `--nodes 35` there are 34 concurrent writers.
*Evidence:* VERIFIED by reading `cluster_instanciate.sh:125-151` + `instanciate_image_outscale.sh:220`.
Whether a torn read actually occurs is **INFERRED** (short `O_APPEND` writes are usually atomic) — the
absence of synchronisation is not.
*Action:* have `instanciate_image_outscale.sh` print the IP on stdout and let the parent
capture it, or write one file per node (`run/node-$n.env`) aggregated after `wait`. The
`tmp_ips_file` pattern already in the recap is the right model — extend it and drop the
`_my_env.sh` round-trip.

### F-20 🔴 Append-only state orphans billable resources
Re-running `osc-setup.sh` creates a second Net and appends a second `OSC_*` block; `source`
keeps the last, so the earlier Net/subnets/SG can never be torn down and keep billing. Same
for `OUTSCALE_INSTANCE_PUBLIC_IP_<n>` across runs. Teardown never prunes the file.
*Evidence:* VERIFIED — `osc/osc-setup.sh:213-227`, `instanciate_image_outscale.sh:220`; the
live `_my_env.sh` already shows one generated block with no sentinels.
*Action:* **port `build_scripts/lib/env_file.sh` from the Build repo** — it already does
sentinel-delimited, rewritten-in-place blocks (temp file + `mv`) and warns on legacy duplicate
assignments. Build's own copy of `osc-setup.sh` already uses it, so the two copies have
diverged with Build ahead. Also refuse to run when a live `OSC_NET_ID` exists unless `--force`.

### F-09 ✅ **FIXED 2026-09-21** — *and the original claim was wrong*
The handover document stated: *"`wait` discards exit status … the script reports success and
prints DNS records for a cluster smaller than requested."* **That is incorrect, and I verified
it.** `set -euo pipefail` is active, `wait "$p"` in a `for` body is not exempt, so a failed node
**did** abort the run. Reproduced with a harness mirroring `cluster_instanciate.sh:125-154`:
one failing subshell ⇒ no recap printed, **exit 1**.

What was actually missing — and is now fixed:
- it aborted on the **first** failing pid, so you learned about one bad node, never all of them;
- **no message said which node failed**, or why;
- the created VMs were left running with no list printed (F-32);
- **nothing ever asked the cluster how many nodes it actually had** — the success banner was
  the script congratulating itself.

*Implemented:* `pid_nodes[]` tracks node numbers alongside `pids[]`; the wait loop uses
`wait "$pid" || rc=$?` (exempt from `set -e`) to collect **every** status; failures are named,
the created-VM list and a diagnostic `ssh` one-liner are printed, and the run exits 1 before
the DNS recap. Then a new verification block runs `rladmin status nodes` on node 1 and
**fails the run unless the cluster itself reports exactly `--nodes` nodes**, dumping the raw
`rladmin` output when it disagrees.
*Verified:* harness cases — all-OK ⇒ recap + exit 0; nodes 3 **and** 5 failing ⇒ both named,
no recap, exit 1; the `grep -oE 'node:[0-9]+' | sort -u | wc -l` count returns 3 on
representative `rladmin status nodes` output.
*Where:* `cluster_instanciate.sh:123-128,150,156-168,178-199,213-227`
*Caveat:* the `rladmin status nodes` parsing has **not** been exercised against a live cluster.
If it miscounts, the run fails loudly and prints the raw output — adjust the `grep` then.

---

## P1 — correctness

### F-04 ✅ **FIXED 2026-09-21** User configuration was silently overridden
`instanciate_image_outscale.sh` sourced `_my_env.sh` (l.4) then **re-declared** `MACHINE_TYPE`,
`FLEX_FLAG`, `FLEX_SIZE_GB`, `VOLUME_TYPE`, `FLEX_IOPS` (l.11-15), discarding the operator's values.
*Evidence (before):* **VERIFIED by execution.** `_my_env.sh` asked for `tinav5.c2r8p3` /
`FLEX_SIZE_GB=20`; the banner printed `tinav5.c2r4p3` / `2 x 40 GiB` — **half the RAM, double
the disk, billed, with no warning.**
*Implemented:* `: "${VAR:=default}"` so the env file wins. `FLEX_FLAG` deliberately uses
`: "${FLEX_FLAG=flex}"` (**no colon**) because `FLEX_FLAG=""` is a meaningful choice —
"no flex" — and `:=` would silently re-enable it.
*Evidence (after):* **VERIFIED by execution.** Same `_my_env.sh` now yields
`Machine type : tinav5.c2r8p3` / `Flex volumes : 2 x 20 GiB (type=io1, IOPS=1000)`; and
`FLEX_FLAG=""` stays empty while an empty `MACHINE_TYPE` still picks up its default.
*Where:* `instanciate_image_outscale.sh:9-20`
*⚠️ Knock-on:* making the config effective also makes **F-31** live. `FLEX_SIZE_GB=20` with
`FLEX_IOPS=1000` sits **exactly** at the io1 cap of 50 IOPS/GiB (50 × 20 = 1000). It was
previously masked by the forced 40 GiB. Legal, but with zero margin.


### F-24 🟠 Private-IP detection is hardcoded to `10/8` and breaks on a multi-address VM
`internal_ip=$(… | grep '^10\.')`. A customer-supplied Net in `172.16/12` or `192.168/16`
yields an empty `internal_ip`, a malformed `/etc/hosts` line, and **no error**. Several `10.*`
addresses make it multi-line and corrupt the same line. Masked today only because
`osc-setup.sh` hardcodes `10.0.0.0/16` — i.e. it breaks exactly in the bring-your-own-network
mode (F-26) that is a product requirement.
*Evidence:* VERIFIED — `image_scripts/create-or-join-redis-cluster.sh:19`.
*Action:* match any RFC1918 range; take the first address; fail loudly if none.

### F-13 🟠 Personal identity hardcoded, ignoring the config that already exists
`--KeypairName "outscale-tmanson-keypair"` is a literal in the `CreateVms` call, and
`connect_to_my_instance.sh` hardcodes `~/.ssh/outscale-tmanson-keypair.rsa` — even though
`OUTSCALE_SSH_KEY` exists and is used elsewhere in the same repo. A customer with a different
keypair gets an unusable VM.
*Evidence:* VERIFIED — `instanciate_image_outscale.sh:134,154`; `connect_to_my_instance.sh:19`.
*Action:* add `OUTSCALE_KEYPAIR_NAME` to the template (Build already has this variable) and
use `$OUTSCALE_SSH_KEY` throughout.

### F-12 🟠 `set -euo pipefail` in the wrong place, or absent
`cluster_instanciate.sh` sources `_my_env.sh` on l.5 and only sets the flags on l.6, so a
broken or missing env file fails silently. `connect_to_my_instance.sh` has **no**
`set -euo pipefail` at all.
*Evidence:* VERIFIED — `cluster_instanciate.sh:5-6`; `connect_to_my_instance.sh:1`.

### F-15 🟠 `ReadVmsState` is called without `--profile`
Neighbouring calls all pass `--profile "$OAPI_PROFILE"`; the readiness poll does not. With a
non-default profile it queries the wrong account and **loops forever** (the loop has no timeout).
*Evidence:* VERIFIED — `instanciate_image_outscale.sh:162`.
*Action:* add the flag, then audit every `oapi-cli` call in the repo.

### F-14 🟠 Fixed `sleep 30` after cluster init instead of polling
`10d933d` already replaced a fixed sleep with real SSH polling; the same treatment was never
applied to cluster readiness. Too short ⇒ every join burns its 10×30 s retry budget; too long
⇒ wasted minutes.
*Evidence:* VERIFIED — `cluster_instanciate.sh:118-119`.
*Action:* poll `rladmin status` (or `curl -sk https://localhost:9443/v1/bootstrap`) until the
cluster answers.

### F-16 🟡 Omitting `--node-num` crashes instead of printing usage
`SUBNET_IDX` is pre-initialised to `""` on l.10; `NODE_IDX` is not, so `set -u` fires before
the friendly check on l.58.
*Evidence:* **VERIFIED by execution** — `./instanciate_image_outscale.sh` (no args) →
`./instanciate_image_outscale.sh: line 58: NODE_IDX: unbound variable`, exit 1.
*Partially FIXED 2026-09-21:* `NODE_IDX=""` added next to `SUBNET_IDX=""`
(`instanciate_image_outscale.sh:15`) while rewriting that block for F-04 — one line, so the
intended usage message now appears instead of the crash. **Still open:** `--subnet` is not
range-checked; `--subnet 4` dies with `OSC_SUBNET4: unbound variable`.

### F-21 🟡 Teardown reports success even when it failed, and can loop forever
Steps 2,4,5,6,7 are all `|| true`, then the script prints `Teardown terminé.` and exits 0 — so
a `DeleteNet` that failed because a dependency survived is reported as success, leaving billable
resources. `wait_vms_terminated()` has no iteration cap.
*Evidence:* VERIFIED — `osc/tear_down_outscale.sh:46-68,99-150`.
*Action:* cap the wait loop; add a final verification pass (`ReadNets`/`ReadVms`) and exit
non-zero if anything survives.

### F-32 🟠 **NEW** No cleanup when the orchestrator aborts
With `set -e`, a failed `wait` aborts `cluster_instanciate.sh` mid-run. There is no `trap`, so
already-created VMs keep running and billing, and the cluster is left half-formed. The operator
has no record of which VMs exist unless the IP append already happened.
*Evidence:* VERIFIED — no `trap` anywhere in `cluster_instanciate.sh`.
*Action:* `trap` that either tears down the partial cluster or prints the exact VM IDs to clean up.

### F-29 🟠 **NEW** `osc-setup.sh` is not transactional, and writes its state last
`set -euo pipefail` plus an env-file append at l.213-227 means a failure at, say, the
security-group step leaves a Net, an Internet Service, a route table and three subnets created
with **no `OSC_*` block written at all** — so `tear_down_outscale.sh`, which reads only that
block, cannot see them. Build's copy already has a TODO at its l.222 acknowledging this
(*"Net précédent introuvable pour tear_down_outscale.sh"*).
*Evidence:* VERIFIED — `osc/osc-setup.sh:213-227`.
*Action:* write each ID to the env file as soon as it is created, not in one block at the end.

### F-31 🟡 **NEW** `io1` IOPS/size ratio is never validated
Outscale caps `io1` at 50 IOPS/GiB. `FLEX_IOPS` defaults to 1000, which is legal only at
≥ 20 GiB. A customer lowering `FLEX_SIZE_GB` gets an opaque `CreateVms` API error.
*Evidence:* VERIFIED — `instanciate_image_outscale.sh:15,103-125`; the constraint is stated in
the repo's own comment (`min 100, max … 20000 for outscale, ratio 50 IOPS/GB`).
*Action:* validate `FLEX_IOPS <= 50 * FLEX_SIZE_GB` before the API call.

### F-35 🟡 **NEW** `flash_enabled` is passed even when Flex is disabled
`create-or-join-redis-cluster.sh` passes `flash_enabled` to both `cluster create` and
`cluster join` unconditionally, but `FLEX_FLAG=""` means no io1 volumes were attached and
`prepare_flash.sh` never ran.
*Evidence:* VERIFIED that it is unconditional (`create-or-join-redis-cluster.sh:54,77`).
Whether `rladmin` rejects it on an unprepared node is **INFERRED** — untested.
*Action:* pass the flag through from `FLEX_FLAG`, and test the non-flex path.

### F-34 🟡 **NEW** `/etc/hosts` is appended to on every invocation
Re-running the bootstrap on a node adds a duplicate entry.
*Evidence:* VERIFIED — `create-or-join-redis-cluster.sh:25` uses `>>` with no de-dup.

### F-30 🟡 **NEW** The "3 AZs" assumption is hardcoded in two independent places
`osc-setup.sh:87` is a literal `for i in 1 2 3` building `${REGION}{a,b,c}`, and
`cluster_instanciate.sh:71`'s `rr_idx()` is `((i-1) % 3) + 1`. A region that does not expose
exactly subregions `a`, `b`, `c` fails at `CreateSubnet`; a region with more gets only 3 used.
*Evidence:* VERIFIED in the code. Which Outscale regions differ is **INFERRED** — only
`eu-west-2` has been exercised.

### F-33 🟡 **NEW** Unbounded API fan-out at the default `--parallel 0`
`--parallel 0` means unlimited, so `--nodes 35` fans out 34 simultaneous `oapi-cli` +
`ssh`/`scp` streams. No retry/backoff on `CreateVms`, and Outscale API throttling is not handled.
*Evidence:* VERIFIED — `cluster_instanciate.sh:10,96-104`. That throttling actually triggers
is **INFERRED** — never tested at N>3.
*Action:* pick a sane non-zero default; add backoff on `CreateVms`.

### F-36 🟡 **NEW** Teardown is unconfirmed and deletes every VM in the Net
It takes no arguments, asks nothing, and `ReadVms --Filters {"NetIds":[…]}` → `DeleteVms`
removes **all** VMs in that Net, including any the customer created there by hand.
*Evidence:* VERIFIED — `osc/tear_down_outscale.sh:84-95`.
*Action:* print the plan and require confirmation (or `--yes`); restrict to VMs tagged by this tool.

### F-11 ✅ **FIXED 2026-09-21** `mktemp` file had no `trap` cleanup
Fixed in passing while touching the same block for F-09: `trap 'rm -f "$tmp_ips_file"' EXIT`
added at `cluster_instanciate.sh:124`. Now that the F-09 guard can `exit 1` mid-run, the trap
matters more than it did.

### F-27 ⚪ Adopt Build's `sleep 15` after VM termination in the teardown
Build waits 15 s between `DeleteVms` and deleting the default route, to let Outscale release
the NICs before the route table is torn down. This repo's copy does not. It is the **only
executable difference** between the two copies, and adopting it makes them identical again.
*Evidence:* VERIFIED from Build's `scripts/shared-drift.baseline`.
*Where:* `osc/tear_down_outscale.sh:~97`

---

## P2 — security hardening

### F-07 🟠 Host-key verification is disabled on every SSH/SCP — on the channel that carries the password
`StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null` everywhere. An on-path attacker can
impersonate a node and harvest the admin credential (F-05).
*Evidence:* VERIFIED — `cluster_instanciate.sh:41`; `instanciate_image_outscale.sh:154,181-182`;
`connect_to_my_instance.sh:19`.
*Status:* **now unblocked.** This was gated on Build `T-11` (the OMI used to ship baked-in host
keys, so trust-on-first-use gave nothing). T-11 is **fixed and verified** — two VMs from
`ami-57a302f4` had distinct host-key fingerprints and distinct machine-ids.
*Action:* read each node's host key from the Outscale console output and pin it into a per-run
`known_hosts`, instead of disabling the check.

### F-28 🟠 **NEW** A root-executed script is staged in an operator-writable directory
`configure_node()` `scp`s `create-or-join-redis-cluster.sh` to `/home/outscale/`, `chmod 700`s
it, then runs it with `sudo`. The file is owned by `outscale` and lives in `outscale`'s home, so
anything able to act as that user between the `chmod` and the `sudo` gets root.
*Evidence:* VERIFIED — `cluster_instanciate.sh:83-92`. Exploitability on a single-tenant node is
low (**INFERRED**), but the pattern is avoidable.
*Action:* stage under a root-owned `mktemp -d` on the node, or bake the script into the OMI (F-39).

### F-17 🟡 "Internal" rules allow `10.0.0.0/8` where the Net is `10.0.0.0/16`
A whole private class A as source.
*Evidence:* VERIFIED — `osc/osc-setup.sh:184,190`.
*Action:* use the security group's **own ID** as source — the idiomatic intra-cluster rule,
immune to CIDR drift.

### F-10 🟡 No private-subnet or bastion topology on offer
All three subnets are public (`MapPublicIpOnLaunch`), every node gets a public IP, and
`external_addr` is the public IP. A customer wanting a private cluster must rewrite the scripts.
*Evidence:* VERIFIED — `osc/osc-setup.sh:110-114`; `instanciate_image_outscale.sh:150`.
*Action:* offer `PUBLIC_NODES=false`: private subnets, NAT for egress, bastion for admin.

### F-19 🟡 Only the Net is tagged
Subnets, route table, Internet Service and security group carry no `Owner` tag, so cost
attribution and orphan hunting are incomplete.
*Evidence:* VERIFIED — `osc/osc-setup.sh:38-41` is the only `CreateTags` for network resources.

### F-08 ⚪ A personal domain is the committed default cluster FQDN
`OUTSCALE_CLUSTER_DNS=outscale.paquerette.com`.
*Evidence:* VERIFIED — `_my_env.template.sh:8`. *Action:* use `redis.example.com`.

### R-07 ⚪ **NEW** `_my_env.sh` permissions are not enforced
It holds `REDIS_PWD` in cleartext and the path to the SSH private key, but nothing `chmod 600`s
it. (Build's copy is mode `0600`.)
*Evidence:* VERIFIED — no `chmod` anywhere in this repo.

---

## P3 — documentation (high impact: this is a customer-facing deliverable)

### R-05 🟠 **NEW** `README.md` documents the pre-split monorepo and is unusable as-is
It was written when this repo also held the AWS target and the Packer templates, and was never
rewritten after `42cf32d`.
*Evidence:* **VERIFIED by execution** — 8 cited paths do not exist:
`packer/ubuntu_ufw_aws_image.pkr.hcl`, `redis-software`, `aws-setup.sh`, `teardown-aws-vpc.sh`,
`osc/my_instanciate_outscale.sh`, `osc/my_instanciate.sh`, `build_scripts`, `_my_env.sh_template`.
And `grep -c cluster_instanciate README.md` → **0**: the real entry point is never named.
It also still teaches the weak template default password (F-06), documents AWS variables (`CLUSTER_DNS`,
`REGION`, `KEY_NAME`), tells the reader to edit `my_instanciate*.sh` for Flex, and its teardown
section says to run `teardown-aws-vpc.sh`.
*Action:* rewrite for the Outscale-only, two-repo world. A first replacement was written in this
pass — review it.

### F-26 🟡 Bring-your-own-network mode works but is undocumented
The maintainer's intent is two modes: (a) provision a throwaway network with `osc-setup.sh`
**for testing**, or (b) **supply the IDs of resources that already exist** in the customer's
account. Mode (b) already works de facto — `instanciate_image_outscale.sh` reads `OSC_SG_ID`,
`OSC_SUBNET{1,2,3}` and `OSC_AZ{1,2,3}` from `_my_env.sh` and never checks who created them —
but nothing says so, and `osc-setup.sh` is presented as a mandatory step 1. A customer with an
existing landing zone will either not realise they can skip it, or run it and get a second Net.
*Evidence:* VERIFIED — `instanciate_image_outscale.sh:86-96` reads the IDs with no provenance check.
*Action:* document both modes; validate the supplied IDs exist (`ReadSubnets`/`ReadSecurityGroups`)
and that the three subnets are in three distinct subregions; state that in mode (b) the
**customer's** security group must carry the Redis Enterprise port matrix.
*Note:* this is also where F-02's CIDR question really lands — in mode (b) the customer already
owns the decision; **mode (a) is the one shipping `0.0.0.0/0`.**

### F-25 🔴 DNS publication is manual and unverified — **this is what broke the first real deploy**
The script only *prints* `A`/`NS` records; nothing checks the operator published them.
*Evidence:* **VERIFIED in production 2026-09-21.** After a fully successful 3-node deploy,
`https://outscale.paquerette.com:8443` was unreachable while the same UI answered **HTTP 200 on
every node's public IP**. Root cause was entirely in DNS — see F-42.
*Severity raised 🟡 → 🔴*: the script's final banner tells the operator the cluster is ready at
an FQDN that does not resolve, and exits 0. That is a false success on the one step a customer
cannot infer.
*Operationally resolved 2026-09-21:* the operator corrected the Gandi zone. **Independently
verified from outside:** the parent now delegates to exactly `ns1`/`ns2`/`ns3` with glue matching
the three live nodes (`80.247.0.247`, `142.44.32.86`, `171.33.104.142`), recursive resolution
works, and `https://outscale.paquerette.com:8443/` returns **HTTP 200**. Databases are reachable
by name. ⇒ **ADR 0004's design (cluster as its own authoritative DNS) is validated end to end.**
The *code* defect stands: the script still prints a success banner for an FQDN it never checks.
*Action:* after printing the records, poll `dig +short NS $OUTSCALE_CLUSTER_DNS` and
`dig +short A $OUTSCALE_CLUSTER_DNS @<node1_ip>` and refuse to print "Cluster setup complete"
until the delegation resolves — or at minimum print "⚠️ not yet resolving" with the IP fallback URL.

### F-38 🟡 **NEW** The OMI↔run version contract is written down nowhere
Nothing records which OMI / Redis Enterprise version this repo's `rladmin` arguments were tested
against. `OUTSCALE_AMI_ID` is an opaque string in a gitignored file. The image is also built
**only in `eu-west-2`** and is not replicated, which no doc in this repo mentions.
*Evidence:* VERIFIED — the only reference to the image is `OUTSCALE_AMI_ID`. Known-good today:
`ami-89fe7cac`, Redis Enterprise **8.2.0-78**, Ubuntu 22.04.
*Action:* record the tested OMI + RE version in `docs/`, and check it at run time if cheap.

### F-39 🟡 `image_scripts/` is `scp`'d at run time although the directory name says it belongs in the image
Build has **deleted** its copy (its `R-02`), so this repo is now the **sole owner** of
`create-or-join-redis-cluster.sh`. The udev `rotational=0` fix in `cluster_instanciate.sh:51-67`
is in the same situation — applied over SSH on every deploy instead of once at image build.
*Evidence:* VERIFIED from Build's findings.
*Action:* decide ownership deliberately, then record it as an ADR. Note F-28 goes away if the
script is baked in.

### F-40 ⚪ No licence installation
`README.md:271-272` — "TODO: Ajout de la license". Per Build's PRD the licence is explicitly the
customer's to supply, so this may be a **docs** task rather than a code one: the cluster runs on
trial limits until a licence is applied, and nothing tells the customer that or how.
*Evidence:* VERIFIED — no licence handling anywhere in either repo.

### F-22 🟠 Shared-file ownership — the premise has changed, re-decide it
`osc/osc-setup.sh` and `osc/tear_down_outscale.sh` exist in both repos. The earlier plan
("Run becomes sole owner, Build deletes its copies") was **withdrawn** on the Build side: the
build legitimately needs its own network, so both copies stay and Build added a `diff`-based
drift guard (`scripts/lint.sh` + `scripts/shared-drift.baseline`). **Build's copies are now
ahead** (`env_file.sh` block rewriting, `mapfile`, `sleep 15`).
*Evidence:* VERIFIED from Build's `docs/findings.md` §1 (revised 2026-09-17).
*Action:* treat it as dual ownership; port Build's improvements here (F-20, F-27); every network
fix above must be applied to **both** copies or the drift guard will fail.
**⚠️ Live as of 2026-09-21:** the F-18 fix touched `osc/osc-setup.sh` here only, taking the diff
from 50 to 62 lines. **Build's `scripts/lint.sh` will fail until** either the same three/four
ports are added to Build's copy, or `scripts/shared-drift.baseline` is refreshed. Decide which —
the ports are arguably correct for Build too, since its copy builds a network with the same
Redis Enterprise port matrix.

### R-03 ⚪ `.gitignore` is a copy of Build's
It still ignores `redis-software/*`, `build_scripts/manifest.json`, `build_scripts/packer.out`,
`build_scripts/install.log` and a `.pem` — none of which exist here. It also **ignores itself**.
*Evidence:* VERIFIED by reading it. The `_my_env.sh` and `.DS_Store` entries are correct and must stay.

### R-04 ⚪ Dead code
`pause()` in `instanciate_image_outscale.sh:5-8` has an **active** `read -rp` and is never
called — if it ever were, it would deadlock the parallel phase. `pause()` in `osc-setup.sh:20-23`
is a no-op stub called 12 times. `safe_unlink_route_table()` in the teardown is defined and never
called.
*Evidence:* VERIFIED — `rg -n 'safe_unlink_route_table|pause' osc/`.

### R-06 ⚪ No lint gate; `shellcheck` exits 1
*Evidence:* **VERIFIED by execution** — 11 findings, listed at the top of this file.
*Action:* fix `SC2087` as part of F-05; convert `SSH_OPTS` to a Bash array (`SC2086` ×2); use
`mapfile` for `VM_IDS` (`SC2207`); add `shellcheck` + `bash -n` as a CI job. Build already has
`.github/workflows/ci.yml` and a `scripts/lint.sh` to copy from.

---

### F-42 🔴 **NEW** The DNS output says what to ADD, never what to REMOVE — stale delegations break the zone
Node IPs change on every deploy, and the node **count** can shrink. The script emits `nsN` records
for `N = 1..--nodes` only, so a previous larger run leaves orphaned `NS` + glue records that no
longer point anywhere. Resolvers try them, get nothing, and the whole zone fails to resolve.
*Evidence:* **VERIFIED in production 2026-09-21.** `paquerette.com` at Gandi still delegated
`outscale.paquerette.com` to **nine** nameservers from an earlier 9-node run:

| glue in the parent zone | probe result |
|---|---|
| ns1 `148.253.123.55`, ns2 `217.75.160.87`, ns3 `80.247.5.96` | udp/53 timeout — dead |
| ns4 `148.253.94.215`, ns5 `5.104.99.122`, ns6 `148.253.104.158` | dead |
| ns7 `142.44.37.84`, ns8 `5.104.101.106`, ns9 `148.253.70.141` | dead |

The live nodes were `80.247.0.247`, `142.44.32.86`, `171.33.104.142` — **zero overlap**. Pasting
the three new records would *still* have left six zombie delegations.
*Action:* print an explicit **"delete these"** section (every `nsN` for `N > --nodes`, plus any
`nsN` whose glue differs from the current IP), and state that glue A records must be *replaced*,
not appended. Better: emit a complete, authoritative zone fragment the operator can paste over
the previous one, plus a `dig`-based verification (F-25).

### F-43 🟡 **NEW** The printed block includes apex `A` records that must not go in the parent zone
`cluster_instanciate.sh:171-174` prints `<cluster_dns>. 10800 IN A <ip>` for every node,
alongside the `NS` delegation for the same name. A delegated name cannot also carry
authoritative data in the parent — those `A` records are ignored at best, rejected by some
providers at worst.
*Evidence:* VERIFIED — the cluster serves its own apex:
`dig +short A outscale.paquerette.com @80.247.0.247` → `80.247.0.247`. The parent needs only the
`NS` records and the `nsN` **glue** A records.
*Action:* drop the apex `A` block, or label it clearly as "informational — served by the cluster,
do not publish". It is the most likely thing for an operator to paste in by mistake.

### F-44 🟠 **NEW** The default `MACHINE_TYPE` cannot host a usable database
`instanciate_image_outscale.sh` defaults to `tinav5.c2r4p3` — **2 vCPU / 4 GB**. Redis Enterprise
reserves a fixed share of node RAM for its control plane, so the figure that governs database
placement (`provisional_ram` / `free_provisioned_memory`) is well below `total_memory`.
*Evidence:* **VERIFIED in production 2026-09-21.** On `tinav5.c2r8p3` (**8 GB**) the operator
measured **~6 GB free provisioned RAM per node**. Creating a RAM database failed with
`Cannot allocate nodes for shards`; **databases below 5 GB allocate successfully** — so the
practical ceiling on an 8 GB node is just under 5 GB, not the 8 GB the machine type advertises.
Extrapolating to the repo default of 4 GB leaves roughly 2 GB per node (**INFERRED** — not
measured), i.e. barely enough for the smallest test database.
*Why it matters:* a customer following the repo as shipped gets a cluster that forms, passes
health checks, and then **refuses to create a database** — with an error that names neither
memory nor sizing. That is a poor first experience for a customer-facing deliverable.
*Also relevant:* only **2 vCPU**. Redis Enterprise wants roughly 1 core per 1-2 shards, so the
default caps useful shard counts regardless of RAM.
*Measured usable ratio:* ~**60%** of the advertised machine-type RAM (under 5 GB usable out of
8 GB). Use that as the sizing rule of thumb until measured on a larger type.
*Constraint that produces the error:* a shard must fit **entirely on one node**, and with
replication its replica must sit on a node in a **different rack** (`rack_aware` is set at
cluster creation). With 3 nodes × 6 GB: a replicated single-shard DB caps at ~6 GB (consuming
12 GB of 18), and a 2-shard replicated DB at 6 GB/shard needs 24 GB ⇒ refused.
*Action:* raise the default to a type with enough RAM for a demonstrable database, document the
`provisional_ram` vs `total_memory` distinction and the sizing arithmetic in the README, and
state the minimum viable type. Now actionable because **F-04** made `MACHINE_TYPE` in
`_my_env.sh` effective.
*Note:* untested at any size — **Auto Tiering (Flex) databases** sidestep the RAM ceiling
entirely and are this project's Outscale differentiator (ADR 0007). The udev `rotational=0`
workaround and `prepare_flash.sh` have been exercised at **cluster** level only, never at
**database** level. Worth validating before the sizing default is changed.

### F-45 ✅ **FIXED 2026-09-21** No way to destroy the cluster while keeping the network
`tear_down_outscale.sh` is all-or-nothing: it deletes every VM in the Net **and then the Net
itself**. There was no "drop the cluster, keep the landing zone" path — the normal operation when
iterating on OMI versions, and the only safe one when the Net is shared (here it belongs to the
Build repo).
*Implemented:* **`osc/destroy_cluster.sh`** — new script. Deliberately applies the lessons of the
findings around it:
- **scoped by default** to VMs tagged `redis-node-<n>`; touching anything else needs `--all-vms`
  (addresses **F-36** on a shared Net);
- **confirmation prompt** with the plan printed first, `-y` to skip (**F-36**);
- **wait loop with a `--timeout`** (default 300 s) that **exits non-zero** on expiry and dumps the
  stuck VMs — unlike `tear_down_outscale.sh`, which can loop forever and always claims success (**F-21**);
- **prunes `OUTSCALE_INSTANCE_PUBLIC_IP_*`** from `_my_env.sh` after a backup, rewriting in place
  so inode and mode `0600` survive (**F-20**, **R-07**);
- **reports volumes still billed** after the VMs are gone;
- **final check that the Net and SG really survived**, exiting non-zero otherwise;
- `--profile "$OAPI_PROFILE"` on **every** call (**F-15**), `set -euo pipefail` **before** the
  `source` (**F-12**).
*Verified:* `bash -n` clean, **`shellcheck` clean (zero findings — the only script in the repo
that is)**. Arg parsing exercised: `--help` exits 0, `--timeout abc` and an unknown flag are
rejected, missing `OSC_NET_ID` fails fast. The `jq` selectors were run against a fixture
`ReadVms` response containing a terminated node, an untagged VM and a foreign `bastion-client` VM:
default scope selected only the two live `redis-node-*` VMs and collected only their volumes
(**not** the foreign VM's), `--all-vms` widened correctly, and the `remaining` counter went 2 → 0.
The env-pruning path was run on a **copy**: 6 IP lines removed, sentinel blocks and all config
keys intact, mode `600` preserved, backup written, file still sources cleanly.
*Not yet run against the live API* — the `oapi-cli` calls themselves are unexercised.
*Where:* `osc/destroy_cluster.sh`

## Validation backlog (V-*)

Test campaigns, as opposed to code defects. Requested by the maintainer 2026-09-21.

### V-1 ⬜ Deploy without Flex (`FLEX_FLAG=""`)
Never exercised. Two specific risks to watch:
- `create-or-join-redis-cluster.sh` passes **`flash_enabled` unconditionally** to both
  `cluster create` and `cluster join`, even with no io1 volumes attached and
  `prepare_flash.sh` never run (**F-35**) — `rladmin` may reject it.
- `cluster_instanciate.sh` skips the whole `FLE_CMD` block, so the udev `rotational=0` rule is
  never written. Confirm nothing else depends on it.
*Gate:* cluster forms, health checks clean, a RAM database under the F-44 ceiling accepts a
client write. Also confirms the `: "${FLEX_FLAG=flex}"` form from **F-04** really preserves an
explicitly empty value in a live run (verified in isolation, not yet on a deploy).

### V-2 ⬜ Deploy in the `production` / private topology
The `production` mode of **ADR 0009** — no public IPs, customer-supplied Net/Subnet/SG, admin
via a bastion. Nothing validated here yet; **everything tested on 2026-09-21 was the `eval`
topology** (public IPs, `CLIENT_CIDR=any`, `OPERATOR_CIDR=any`).
*Blocked on code that does not exist:* private subnets + NAT egress + bastion (**F-10**),
validation of supplied resource IDs (**F-26**), the `redis-enterprise-firewall` re-scoping call
(**F-41** residue), and critically **F-24** — the node bootstrap detects its own address with
`grep '^10\.'`, so a customer network in `172.16/12` or `192.168/16` breaks before the cluster
forms.
*Open design question:* with no public IP, `external_addr` must become the private address, and
the DNS delegation only works inside the customer's network. Worth deciding before building it.

---

## Closed / not applicable

### F-23 ✅ Sole ownership of `create-or-join-redis-cluster.sh` — **satisfied**
It was byte-identical in both repos; Build has **deleted its copy** (its `R-02`, landed in
Build PR 2), so this repo is now the sole owner. Nothing to do here beyond being aware that
edits to it no longer need mirroring. Where the file *should* live is still open — see F-39.
*Evidence:* VERIFIED from Build's `docs/findings.md`.

*(`F-37` is unused — the register jumps from `F-36` to `F-38`. Left as a gap rather than
renumbered, so IDs stay stable across both repos.)*

## Suggested order

The prior audit's order, amended for what has changed since it was written:

0. **F-41 first** — run `--nodes 3` against `ami-89fe7cac` and find out whether the image's new
   active `ufw` lets a cluster form at all. Everything else is speculative until that is known,
   and it is also the gate Build is waiting on for its `T-19`.
1. **F-06 → F-05** — the committed weak default, then the four password leak points. Cheapest,
   highest severity, and as of the 2026-09-21 deploy the operator's live `_my_env.sh` had
   not been moved off the committed template default.
2. **F-18 + F-02 + F-03 + F-17** — the security-group set: add the three missing internal ports,
   give the customer the exposure knob, drop cleartext 8080, tighten the internal source.
3. **F-07** — now unblocked by Build `T-11`; pin host keys instead of disabling verification.
4. **F-01 + F-20 + F-09 + F-32** — get `_my_env.sh` out of the parallel path (port Build's
   `env_file.sh`), stop orphaning Nets, make a failed node fail the run.
5. **F-04, F-12, F-13, F-15, F-16, F-24** — configuration correctness. **F-04 is currently
   giving the customer half the configured RAM and double the configured disk.**
6. **R-05 + F-26 + F-25 + F-38** — the docs, since this is a customer-facing deliverable.
7. **R-06** — CI gate (`shellcheck` + `bash -n`), copied from Build.
8. Remaining 🟡/⚪ items.

## Decisions taken 2026-09-21 (maintainer)

| Question | Answer | Effect on this backlog |
|---|---|---|
| Target exposure model | **Two explicit modes, `eval` and `production`** — see `adr/0009` | F-02, F-10, F-26 merge into one design task; F-24 is promoted from latent to blocking (a customer network outside `10/8` breaks node bootstrap) |
| Is a load balancer missing? | **No — deliberately none.** The cluster's own authoritative DNS is the design | `adr/0004`'s rationale is now VERIFIED; no LB task is created |
| bash vs OpenTofu | **Stay on bash + `oapi-cli`** — customer auditability is a feature | F-20, F-29, F-21, F-36 stay as individual fixes; F-20 is fixed by porting Build's `env_file.sh`, not by adopting IaC |
| What first? | **Run the F-41 validation deploy now** | F-41 is the immediate next action; everything below it stays speculative until it runs |

## Still open for the maintainer

1. **Keypair (F-13)** — add `OUTSCALE_KEYPAIR_NAME` to the template (Build already has that
   variable), or is the hardcoded `outscale-tmanson-keypair` deliberate for now?
2. **Max nodes = 35 (adr/0006)** — is that a real Redis Enterprise limit or a round number?
   It is currently INFERRED.
3. **Where should the node-side code live (F-39)?** `create-or-join-redis-cluster.sh` and the
   udev `rotational=0` fix are pushed over SSH on every deploy. Baking them into the OMI would
   also close F-28 — but Build has deliberately deleted its copy, so this is a real choice.
4. **F-04, concretely** — your live `_my_env.sh` asks for `tinav5.c2r8p3` and `FLEX_SIZE_GB=20`
   but you are being given `tinav5.c2r4p3` and 2×40 GiB. Which set do you actually want as the
   default once the override bug is fixed?
