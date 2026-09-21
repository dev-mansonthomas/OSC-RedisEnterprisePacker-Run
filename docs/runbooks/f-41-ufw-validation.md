# Runbook — F-41: validate the image's active `ufw` against a real cluster

**Goal:** answer one question — *does a 3-node cluster still form now that the OMI boots with
`ufw` enabled and enforcing?* This also discharges Build's `T-19`, whose stated gate is
exactly this run.

**Where:** on the **host**, not in the dev VM. The VM has no `oapi-cli` and no Outscale
credentials by design. Everything below is for you to run and review.

**Duration:** ~10 min for the deploy, ~15 min including diagnostics.

**Expected cost:** 3 × `tinav5.c2r4p3` + 6 × 40 GiB io1, for well under an hour.

---

## 0. Pre-flight (do not skip — two of these will bite)

```sh
cd ~/Projects/OSC-RedisEnterprisePacker-Run
```

**a. Use a throwaway admin password for this run.** F-05 is not fixed, so whatever you set
will land in each node's `auth.log`, in your terminal, and in the node's process list. Set
something disposable now and rotate it in the UI afterwards if you keep the cluster.

```sh
grep -n '^REDIS_PWD' _my_env.sh     # still the committed template default? change it (F-06)
```

**b. Clear the stale per-node IPs.** `_my_env.sh` already holds
`OUTSCALE_INSTANCE_PUBLIC_IP_1..3` from a previous run. New lines are appended and win, *but*
if a node fails to launch the stale IP silently takes over and the script will SSH into a host
that is gone or belongs to someone else. Remove them first (F-20):

```sh
cp _my_env.sh _my_env.sh.bak
sed -i.tmp '/^OUTSCALE_INSTANCE_PUBLIC_IP_/d' _my_env.sh && rm -f _my_env.sh.tmp
grep -c '^OUTSCALE_INSTANCE_PUBLIC_IP_' _my_env.sh   # expect 0
```

**c. Confirm the recorded network still exists.** If it was torn down, `CreateVms` will fail
with an unhelpful subnet error:

```sh
source _my_env.sh
oapi-cli ReadNets   --Filters "{\"NetIds\":[\"$OSC_NET_ID\"]}"       | jq '.Nets | length'
oapi-cli ReadSubnets --Filters "{\"SubnetIds\":[\"$OSC_SUBNET1\",\"$OSC_SUBNET2\",\"$OSC_SUBNET3\"]}" | jq '.Subnets | length'
oapi-cli ReadSecurityGroups --Filters "{\"SecurityGroupIds\":[\"$OSC_SG_ID\"]}" | jq '.SecurityGroups | length'
```

Expect `1`, `3`, `1`. If any is `0`, re-run `cd osc && ./osc-setup.sh` — and then **delete the
older `OSC_*` block from `_my_env.sh` by hand**, or you will orphan a Net (F-20).

**d. Confirm the OMI.** Known-good is `ami-89fe7cac` (Redis Enterprise 8.2.0-78, Ubuntu 22.04,
`eu-west-2`).

```sh
grep -n '^OUTSCALE_AMI_ID' _my_env.sh
oapi-cli ReadImages --Filters "{\"ImageIds\":[\"$OUTSCALE_AMI_ID\"]}" | jq -r '.Images[] | .ImageName, .State'
```

**e. Note the keypair mismatch (F-13).** The script hardcodes
`--KeypairName "outscale-tmanson-keypair"`. If that is still your keypair, fine.

## 1. Run it, and keep the log

```sh
cd osc
mkdir -p ../debug
./cluster_instanciate.sh --nodes 3 2>&1 | tee ../debug/f41-deploy-$(date +%Y%m%dT%H%M%S).log
```

Watch for:

- `SSH is ready on <ip> after N attempt(s)` — three times. If a node times out at 600 s, the
  security group or the keypair is wrong, **not** `ufw` (the host firewall always allows 22).
- `Rejoint le cluster avec succès.` — twice (nodes 2 and 3).
- `Master non prêt, nouvelle tentative dans 30s...` — **this is the signal to care about.**
  One or two retries is the `sleep 30` being marginal (F-14). Burning all ten and failing is
  the `ufw` hypothesis.

## 2. Verify the cluster actually formed

Do not trust the script's success banner — F-09 means a failed node is merely absent from the
recap, and the run still reports success.

```sh
source ../_my_env.sh
ssh -o StrictHostKeyChecking=no -i "$OUTSCALE_SSH_KEY" \
    outscale@"$OUTSCALE_INSTANCE_PUBLIC_IP_1" \
    'sudo /opt/redislabs/bin/rladmin status' | tee ../debug/f41-rladmin-status.txt
```

Acceptance:

- **3** nodes listed, all `active`.
- Three distinct `rack_id` values (`eu-west-2a`, `-2b`, `-2c`) — rack awareness held.
- Cluster name == your `OUTSCALE_CLUSTER_DNS`.

## 3. Capture the firewall state (the actual point of this run)

For each node IP:

```sh
for ip in "$OUTSCALE_INSTANCE_PUBLIC_IP_1" "$OUTSCALE_INSTANCE_PUBLIC_IP_2" "$OUTSCALE_INSTANCE_PUBLIC_IP_3"; do
  echo "########## $ip"
  ssh -o StrictHostKeyChecking=no -i "$OUTSCALE_SSH_KEY" outscale@"$ip" '
    echo "--- ufw ---";            sudo ufw status verbose
    echo "--- UFW BLOCK drops ---"; sudo journalctl -k --no-pager | grep "UFW BLOCK" | tail -40
    echo "--- drop count by port ---"
    sudo journalctl -k --no-pager | grep -o "DPT=[0-9]*" | sort | uniq -c | sort -rn | head -20
    echo "--- init log (password redacted) ---"
    sudo sed -E "s/(RS_password=).*/\1<redacted>/" /var/log/redis-enterprise-init.log | tail -40
  '
done 2>&1 | tee ../debug/f41-firewall-$(date +%Y%m%dT%H%M%S).txt
```

**The decisive artefact is the drop-count-by-port table.** Any `DPT=` there that Redis
Enterprise needs is a rule the image's firewall is missing.

Cross-check against the ports the security group is **also** missing — `8444`, `3357`, `8000`
(F-18). If those show up as UFW drops too, both firewalls need the same three ports and the
two findings have one fix.

## 4. Functional check through both firewalls

From your workstation (or the bastion), after publishing the DNS records:

```sh
curl -sk -o /dev/null -w '%{http_code}\n' "https://$OUTSCALE_CLUSTER_DNS:8443/"   # expect 200
curl -sk -u "$REDIS_LOGIN:$REDIS_PWD" "https://$OUTSCALE_CLUSTER_DNS:9443/v1/nodes" | jq 'length'  # expect 3
```

Then create a small database in the UI and:

```sh
redis-cli -h "redis-12000.$OUTSCALE_CLUSTER_DNS" -p 12000 PING     # expect PONG
```

`PONG` is the end-to-end proof: cluster + DNS delegation + security group + host `ufw`.

## 5. Record the outcome

Write the result into `docs/tasks.md` under F-41, and tell the Build repo — its `T-19` is
waiting on this.

| Outcome | What it means | Next |
|---|---|---|
| Cluster forms, no relevant UFW drops | The image's default port-scope rules are sufficient | Close F-41's validation half; the re-scoping call (`redis-enterprise-firewall`) becomes a P1 hardening task, not a blocker |
| Cluster forms, but UFW drops on RE ports | Works by luck / retries; fragile | Add the missing ports to **both** the image's `CLUSTER_TCP` (Build) and the security group (F-18) |
| Cluster does not form | The `ufw` + SG combination is broken as shipped | Compare the UFW drop table against Redis's port matrix; fix Build's rule set; re-run |
| Fails for an unrelated reason | e.g. keypair (F-13), stale IPs (F-20), IOPS ratio (F-31) | Fix that, re-run — the `ufw` question is still unanswered |

## 6. Tear down

```sh
cd osc && ./tear_down_outscale.sh
```

Then **verify**, because it reports success unconditionally (F-21):

```sh
source ../_my_env.sh
oapi-cli ReadVms  --Filters "{\"NetIds\":[\"$OSC_NET_ID\"]}" | jq '.Vms  | length'   # expect 0
oapi-cli ReadNets --Filters "{\"NetIds\":[\"$OSC_NET_ID\"]}" | jq '.Nets | length'   # expect 0
```

If you tore the network down, remove the `OSC_*` lines from `_my_env.sh` before the next run.
