# ADR 0003 — Pre-built OMI; build and run live in separate repos

**Status:** Accepted (split landed 2025-09-29, commit `42cf32d`)

## Decision
Redis Enterprise is installed once, at image-build time, by a *separate* repo
(`OSC-RedisEnterprisePacker-Build`, Packer-based, run by Redis). This repo only consumes the
resulting OMI ID and does the cluster-formation work at boot.

## Evidence (VERIFIED)
- `git log --diff-filter=D` shows `packer/*.pkr.hcl`, `build_scripts/`,
  `image_scripts/install-redis.sh` and `image_scripts/prepare-redis-install.sh` were all
  **deleted** from this repo; commit message: *"Cleanup to keep run on Outscale"*.
- The only surviving input is `OUTSCALE_AMI_ID` in `_my_env.sh`.
- Run-time scripts call `/opt/redislabs/bin/rladmin` and `/opt/redislabs/sbin/prepare_flash.sh`
  without ever installing them.

## Rationale (VERIFIED from the project framing)
The two halves have different owners and different trust levels: Redis builds and publishes
the image; the customer runs the deployment inside their own tenancy. Splitting the repos
makes that boundary explicit and keeps the Redis Enterprise tarball and licence out of the
customer-facing repo.

## Consequences
- **Accepted:** fast boots (no apt/install at run time), a reproducible artifact, and a clean
  ownership boundary.
- **Cost:** a versioning contract now exists between the two repos and **is not written down
  anywhere** — nothing pins which OMI version this repo's `rladmin` arguments were tested
  against. Tracked as `F-38`.
- `image_scripts/create-or-join-redis-cluster.sh` stayed behind in the *run* repo and is
  `scp`'d at run time, even though its directory name says it belongs in the image (`F-39`).
- `README.md` still documents the pre-split world (`R-05`).
