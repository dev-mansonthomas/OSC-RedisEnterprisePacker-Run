# ADR 0007 — Flex / Auto Tiering on 2× io1 volumes, with a udev `rotational=0` override

**Status:** Accepted (2025-09-10, commit `699110c` "Flex working on outscale")

## Decision
When `FLEX_FLAG=flex`, attach two `io1` BSU volumes per node (`/dev/sdf`, `/dev/sdg`) and,
before running Redis Enterprise's `prepare_flash.sh`, install a udev rule forcing
`queue/rotational=0` on all `sd*`/`vd*` devices.

## Evidence (VERIFIED)
- `instanciate_image_outscale.sh:99-126` — `jq`-built `BlockDeviceMappings` with two
  `io1` volumes, `DeleteOnVmDeletion=true`.
- `cluster_instanciate.sh:51-67` — writes `/etc/udev/rules.d/99-rotational-fix.rules`,
  `udevadm control --reload`, `udevadm trigger --action=change` per device, then
  `sudo /opt/redislabs/sbin/prepare_flash.sh -y`.
- The in-code comment states the reason: *"Utile pour le cloud Outscale où les volumes io1
  peuvent être mal détectés par le kernel. Cette étape n'est pas forcément nécessaire sur
  d'autres clouds."*
- `flash_enabled` is passed to both `rladmin cluster create` and `cluster join`.
- Two volumes because `prepare_flash.sh` stripes them RAID0 — per `README.md:126`, usable
  capacity is `2 × FLEX_SIZE_GB`.

## Rationale (VERIFIED from the comment + history)
Redis Enterprise refuses to use a device for flash if the kernel reports it as rotational.
Outscale's io1 volumes are misreported, so `prepare_flash.sh` would reject them; the udev
rule is a targeted workaround. Commit `34c7939` records the symptom before the fix: *"The
cluster do not have flash fully enabled for some reasons"*.

## Consequences
- **Accepted:** Auto Tiering works on Outscale, giving RAM+SSD capacity at lower cost —
  the main reason to pick io1 over gp2.
- **Cost:** the udev rule is applied cluster-wide and lies to the kernel about *every* block
  device, not just the two flash volumes.
- **Cost:** `io1` requires `Iops ≤ 50 × VolumeSize`; nothing validates this, so a small
  `FLEX_SIZE_GB` with the default 1000 IOPS fails with an opaque API error (`F-31`).
- **Cost:** `flash_enabled` is passed even when `FLEX_FLAG` is empty (`F-35`).
- The fix belongs in the OMI (build repo), not in the run-time orchestrator — it is applied
  over SSH on every deploy instead of once at image build (`F-39`).
