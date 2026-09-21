# Redis Enterprise on Outscale — deployment scripts

Deploy a **Redis Enterprise cluster** on [Outscale](https://outscale.com) from a pre-built
machine image (OMI): 3 to 35 nodes, spread across three availability zones, clustered
automatically. A 3-node cluster takes about **5 minutes**.

This README assumes **no prior knowledge** of Outscale or Redis Enterprise. Follow it top to
bottom and copy-paste.

> **Reconstructed 2026-09-21.** This repo had no working documentation; this README was
> rebuilt from the code. The commands below are read off the scripts, but **the flow has not
> been re-run end-to-end** since the image gained a host firewall — see
> [Known issues](#known-issues) before you rely on it.

---

## ⚠️ Read this before you deploy

**As shipped, `osc/osc-setup.sh` opens the cluster to the entire internet** — the admin UI
(port 8443), the REST API (9443, 3346) and every database port (10000-19999) are reachable
from `0.0.0.0/0`. That is fine for a throwaway evaluation and **not** fine for production or
anything SecNumCloud-adjacent.

If that is not what you want, either:

- edit the `--IpRange "0.0.0.0/0"` values in `osc/osc-setup.sh` to your own CIDR before
  running it, **or**
- skip `osc-setup.sh` entirely and point the scripts at network resources you already own
  (see [Mode B](#mode-b--use-your-own-network)).

Also: **choose a real admin password.** The old template shipped a weak default.

Tracked as `docs/tasks.md` F-02 and F-06.

---

## 1. What you need

| | |
|---|---|
| An Outscale account | with an access key — [Outscale Cockpit](https://cockpit.outscale.com/#/accesskeys) |
| A Redis Enterprise OMI | built by the companion repo `OSC-RedisEnterprisePacker-Build`. Known-good: `ami-89fe7cac` (Redis Enterprise 8.2.0-78, Ubuntu 22.04, region `eu-west-2`). **The image exists only in the region it was built in.** |
| A domain name you control | with the ability to add `A` and `NS` records — e.g. `redis.example.com` |
| A Linux or macOS machine | bash 5 or zsh. A VM inside Outscale is the more secure choice. |
| `oapi-cli`, `jq`, `ssh` | installed below |

You do **not** need Packer, Terraform, or a Redis Enterprise download — that is all the Build
repo's job.

## 2. Install the tools

```sh
# macOS (Homebrew)
brew tap outscale/tap
brew install outscale/tap/oapi-cli jq
```

Other platforms: see [oapi-cli releases](https://github.com/outscale/oapi-cli).

## 3. Configure Outscale authentication

Create your access key in the [Cockpit](https://cockpit.outscale.com/#/accesskeys), then:

```sh
mkdir -p ~/.osc
cat > ~/.osc/config.json <<'EOF'
{
  "default": {
    "access_key": "YOUR_ACCESS_KEY",
    "secret_key": "YOUR_SECRET_KEY",
    "region": "eu-west-2"
  }
}
EOF
chmod 600 ~/.osc/config.json
```

**Check it works:**

```sh
oapi-cli ReadVms
```

Success looks like this (an empty `Vms` list is fine — it means you have no VMs yet):

```json
{
  "ResponseContext": { "RequestId": "a79c959b-c6c0-4087-b687-6b20f2dfc1a5" },
  "Vms": []
}
```

If you get an authentication error, re-check the keys and the region.

## 4. Create an SSH key pair

```sh
oapi-cli --profile default CreateKeypair --KeypairName "my-redis-keypair"
```

The response contains a `PrivateKey` field with literal `\n` sequences. Save it as a real
file with real newlines:

```sh
# paste the PrivateKey value (without the surrounding quotes) into a file, then:
printf '%b\n' "$(cat /tmp/key.raw)" > ~/.ssh/my-redis-keypair.rsa
chmod 600 ~/.ssh/my-redis-keypair.rsa
ssh-keygen -y -f ~/.ssh/my-redis-keypair.rsa >/dev/null && echo "key is valid"
```

The last command prints `key is valid` if the file is a usable private key.

> **Heads up:** the keypair name is currently **hardcoded** to `outscale-tmanson-keypair` in
> `osc/instanciate_image_outscale.sh:134` and `osc/connect_to_my_instance.sh:19`. Until
> `docs/tasks.md` F-13 is fixed, either name your keypair exactly that, or edit those two
> lines to your own name.

## 5. Configure the deployment

```sh
cp _my_env.template.sh _my_env.sh
chmod 600 _my_env.sh            # it will hold your admin password
```

Generate a strong admin password and edit `_my_env.sh`:

```sh
openssl rand -base64 24         # use this as REDIS_PWD — do not keep the template default
```

```sh
OWNER="your-name"                                   # tags + resource names
OUTSCALE_REGION=eu-west-2                           # must match your access key's region
OUTSCALE_SSH_KEY="$HOME/.ssh/my-redis-keypair.rsa"  # the file from step 4

REDIS_LOGIN=admin@example.com                       # Redis Enterprise admin login
REDIS_PWD='<paste the generated password>'          # NOT the template default

OUTSCALE_CLUSTER_DNS=redis.example.com              # the FQDN you will delegate in step 8

FLEX_FLAG="flex"        # "" to disable Auto Tiering (RAM+SSD)
FLEX_SIZE_GB="40"       # per volume; 2 volumes in RAID0, so usable = 2x this
FLEX_IOPS="1000"        # io1 limit is 50 IOPS per GiB, so keep FLEX_IOPS <= 50*FLEX_SIZE_GB
MACHINE_TYPE="tinav5.c2r4p3"

OUTSCALE_AMI_ID=ami-89fe7cac                        # the OMI from the Build repo
```

> **Known bug (`docs/tasks.md` F-04):** `MACHINE_TYPE`, `FLEX_FLAG`, `FLEX_SIZE_GB` and
> `FLEX_IOPS` in this file are currently **ignored** — `osc/instanciate_image_outscale.sh`
> re-hardcodes them on lines 11-15 (`tinav5.c2r4p3`, `flex`, `40 GB`, `1000` IOPS). To change
> them today, edit those lines. The values above match the hardcoded ones so there is no
> surprise.

`_my_env.sh` is gitignored. **Never commit it** — it holds your admin password.

## 6. Create the network

### Mode A — let the script build a throwaway network

```sh
cd osc
./osc-setup.sh
```

Takes about a minute. It creates a Net (`10.0.0.0/16`), an internet gateway, a route table,
three public subnets (one per availability zone) and one security group, then **appends** the
resulting IDs to `../_my_env.sh`:

```sh
OSC_NET_ID=vpc-...      OSC_SUBNET1=subnet-...   OSC_AZ1=eu-west-2a
OSC_IGW_ID=igw-...      OSC_SUBNET2=subnet-...   OSC_AZ2=eu-west-2b
OSC_RTB_ID=rtb-...      OSC_SUBNET3=subnet-...   OSC_AZ3=eu-west-2c
OSC_SG_ID=sg-...
```

> **Run it once.** It is not idempotent: a second run creates a *second* Net and appends a
> *second* block. The scripts use the last block, so the first Net becomes invisible to the
> teardown script and keeps costing you money. If you need to start over, run
> `./tear_down_outscale.sh` first, then **delete the generated lines from `_my_env.sh` by
> hand**. Tracked as `docs/tasks.md` F-20.

### Mode B — use your own network

If you already have a landing zone, **skip `osc-setup.sh`** and fill in those nine variables
yourself. The deployment scripts never check who created the resources. You need:

- **three subnets in three distinct availability zones**, each with public IP assignment on
  launch (or see F-10 about private topologies);
- **a security group carrying the full Redis Enterprise port matrix.** Copy the rule set from
  `osc/osc-setup.sh:132-199` — and add `8444`, `3357` and `8000`, which that script is
  currently missing (`docs/tasks.md` F-18);
- **a private CIDR inside `10.0.0.0/8`.** The node bootstrap script detects its own address
  with `grep '^10\.'`, so a `172.16/12` or `192.168/16` network **will fail** until
  `docs/tasks.md` F-24 is fixed.

## 7. Deploy the cluster

```sh
cd osc
./cluster_instanciate.sh --nodes 3
```

| Option | Default | Notes |
|---|---|---|
| `--nodes <N>` | `3` | must be **odd**, between 3 and 35 — Redis Enterprise needs an odd quorum |
| `--parallel <0\|N>` | `0` | `0` = no limit. Consider `--parallel 5` for large clusters |

What happens: node 1 boots and runs `rladmin cluster create`; nodes 2..N boot in parallel and
`rladmin cluster join`. Nodes are placed round-robin across your three AZs, and each node's AZ
becomes its Redis Enterprise `rack_id`, so the cluster is rack-aware.

The script ends by printing the DNS records you need and the cluster URL.

## 8. Publish the DNS records

Copy the block the script printed into your DNS zone. It looks like this:

```
ns1.redis.example.com. 10800 IN A 171.33.65.166
ns2.redis.example.com. 10800 IN A 171.33.82.31
ns3.redis.example.com. 10800 IN A 171.33.83.16

redis.example.com. 10800 IN A 171.33.65.166
redis.example.com. 10800 IN A 171.33.82.31
redis.example.com. 10800 IN A 171.33.83.16

redis.example.com. 10800 IN NS ns1.redis.example.com.
redis.example.com. 10800 IN NS ns2.redis.example.com.
redis.example.com. 10800 IN NS ns3.redis.example.com.
```

**This step is mandatory, not cosmetic.** The `NS` records delegate the zone to the cluster
itself, which runs its own DNS server — that is what makes each database endpoint
(`redis-12000.redis.example.com`) resolve and fail over. Nothing verifies you did it; without
it the cluster is reachable only by raw IP.

Don't want to wait for propagation? Flush your local cache:

```sh
# macOS
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
# Linux
sudo resolvectl flush-caches
```

Check it took effect:

```sh
dig +short NS redis.example.com
dig +short redis.example.com
```

## 9. Open the Cluster Manager

Go to `https://redis.example.com:8443` and log in with the `REDIS_LOGIN` /
`REDIS_PWD` from step 5. The certificate is self-signed, so your browser will warn you.

**Verify the deployment:**

1. **Nodes** tab — all N nodes present and green.
2. **Cluster** tab — rack-aware enabled, N nodes, quorum healthy.
3. Create a small database, note its port (e.g. 12000), and connect:
   ```sh
   redis-cli -h redis-12000.redis.example.com -p 12000 PING
   ```
   `PONG` means the whole chain — cluster, DNS delegation, firewall — works.

## 10. Log into a node

```sh
cd osc
./connect_to_my_instance.sh 1      # 1 = node number
```

Useful once you are on a node:

```sh
sudo /opt/redislabs/bin/rladmin status        # cluster state
sudo cat /var/log/redis-enterprise-init.log   # what the bootstrap script did
sudo ufw status verbose                       # the host firewall baked into the image
sudo journalctl -k | grep 'UFW BLOCK'         # what the host firewall is dropping
```

## Recycling vs. teardown

**To replace the cluster but keep the network** (the usual case — and the only safe one if the
Net is shared with another project):

```sh
cd osc
./destroy_cluster.sh            # add -y to skip the confirmation prompt
```

It deletes only the VMs tagged `redis-node-<n>`, waits for them to actually terminate (with a
timeout), prunes the stale node IPs from `_my_env.sh`, warns about any volume still billed, and
checks the Net and security group survived. Then just re-run `./cluster_instanciate.sh`.

**To destroy everything, network included:**

```sh
cd osc
./tear_down_outscale.sh
```

⚠️ **It asks no questions, and it deletes _every_ VM in the Net** — including any you created
there by hand. It reads the resource IDs from `_my_env.sh`.

⚠️ **It prints `Teardown terminé.` even when steps failed.** Always verify, and expect to
clean up `_my_env.sh` yourself:

```sh
oapi-cli ReadVms  --Filters '{"NetIds":["vpc-xxxxxxxx"]}'   # should be empty
oapi-cli ReadNets --Filters '{"NetIds":["vpc-xxxxxxxx"]}'   # should be empty
```

Tracked as `docs/tasks.md` F-21, F-36.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `NODE_IDX: unbound variable` | you ran `instanciate_image_outscale.sh` without `--node-num`. Known bug F-16 — the real message should be a usage hint. |
| Nodes boot but never join the cluster | The OMI ships an **active `ufw`**. Check `sudo journalctl -k \| grep 'UFW BLOCK'` on the node, and see F-41 — this combination has not yet been validated end-to-end. |
| `CreateVms` fails with an IOPS error | `io1` allows at most 50 IOPS per GiB. Keep `FLEX_IOPS <= 50 * FLEX_SIZE_GB` (F-31). |
| The readiness poll never finishes | If you use a non-`default` `oapi-cli` profile, the `ReadVmsState` poll queries the wrong account and loops forever (F-15). |
| `SSH not ready after 600s` | Check the security group allows port 22 from your address, and that `OUTSCALE_SSH_KEY` matches the keypair the VM was created with (F-13). |
| Cluster forms but the UI or metrics misbehave | Ports `8444`, `3357`, `8000` are missing from the security group (F-18). |
| Teardown said it worked but resources remain | F-21. Verify with the `oapi-cli` commands above and delete by hand. |

## Known issues

This repo has an audited backlog. **Read `docs/tasks.md` before a production deployment** —
the highest-severity items are:

- **F-41** — the OMI now ships an enforcing host firewall (`ufw`); the scripts never re-scope
  it and the combination has never been run against a real cluster.
- **F-02** — the security group defaults to `0.0.0.0/0` on the admin plane and all database ports.
- **F-05 / F-06** — the admin password leaks into each node's system log, the operator's
  terminal, and the node's process list; a weak default used to ship in git.
- **F-04** — `MACHINE_TYPE` and the Flex settings in `_my_env.sh` are silently ignored.
- **F-20** — re-running `osc-setup.sh` orphans billable resources.

## Documentation map

| For | Read |
|---|---|
| Agents / newcomers to the code | [`CLAUDE.md`](CLAUDE.md) |
| How the pieces fit together | [`docs/architecture/overview.md`](docs/architecture/overview.md) |
| What each script's contract is | [`docs/specs/`](docs/specs/) |
| Why it is built this way | [`docs/adr/`](docs/adr/) |
| What is wrong with it | [`docs/tasks.md`](docs/tasks.md) |
| The next thing to run | [`docs/runbooks/f-41-ufw-validation.md`](docs/runbooks/f-41-ufw-validation.md) |
| Problem, users, scope | [`docs/product/PRD.md`](docs/product/PRD.md) |
| How the image is built | the `OSC-RedisEnterprisePacker-Build` repo |
