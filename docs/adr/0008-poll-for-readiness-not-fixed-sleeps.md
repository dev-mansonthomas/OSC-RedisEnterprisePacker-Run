# ADR 0008 — Poll for readiness instead of sleeping

**Status:** Accepted (2025-09-30, commit `10d933d`) · **partially applied**

## Decision
Replace fixed `sleep`s with active readiness probes, and parallelise nodes 2..N.

## Evidence (VERIFIED)
- Commit `10d933d`: *"Test for SSH availability instead of a sleep: we randomly get long time
  for SSH server to be available, that fixes that — spawn nodes 2 to N in parallel to speed up
  cluster creation time. It should consistently takes around 5 minutes, whatever the number
  of nodes"*.
- `instanciate_image_outscale.sh:159-165` — polls `ReadVmsState` every 3 s until `running`.
- `instanciate_image_outscale.sh:194-216` — TCP probe on `/dev/tcp/$IP/22` **then** a real
  `ssh -o BatchMode=yes … true` handshake, `MAX_WAIT=600`, `SLEEP_STEP=5`.
- `cluster_instanciate.sh:125-154` — nodes 2..N in background subshells + `wait`.

## Rationale (VERIFIED from the commit message)
SSH availability after boot was highly variable; a fixed sleep was either too short (flaky
failures) or too long (wasted minutes). Serial node creation made wall-clock grow linearly
with N.

## Consequences
- **Accepted:** deploys are reliable and roughly constant-time in N.
- **Not finished:** three waits still violate the principle —
  `sleep 30` after cluster create (`cluster_instanciate.sh:119`, `F-14`),
  `sleep $i` as a stagger (`:129`), and the `sleep 30` × 10 retry loop inside
  `join_master()`. The cluster's own readiness is never polled.
- **New cost:** parallelism introduced unsynchronised concurrent access to `_my_env.sh`
  (`F-01`), unbounded API fan-out at `--parallel 0` (`F-33`), and a failure mode where
  an aborted orchestrator leaves billable VMs behind (`F-32`).
- Both remaining poll loops (`ReadVmsState`, `wait_vms_terminated`) still lack timeouts.
