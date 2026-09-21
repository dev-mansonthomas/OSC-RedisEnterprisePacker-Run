# Architecture Decision Records

ADRs 0001-0008 are **read off the existing code** on 2026-09-21; 0009 is a **forward
decision** taken that day and not yet implemented. The *decision* and the
*evidence* are VERIFIED; the *rationale* is **INFERRED** unless the git history states it.
They are recorded here so the choices are challengeable, not to bless them.

| # | Decision | Status |
|---|---|---|
| [0001](0001-bash-and-oapi-cli-over-terraform.md) | Bash + `oapi-cli` instead of Terraform/OpenTofu | Accepted, **re-affirmed 2026-09-21** |
| [0002](0002-env-file-as-state.md) | A sourced, append-only `_my_env.sh` as the only state | Accepted, **contested** |
| [0003](0003-prebuilt-omi-split-build-and-run.md) | Pre-built OMI, build and run in separate repos | Accepted |
| [0004](0004-public-ips-and-self-hosted-dns.md) | Public IP per node + Redis Enterprise as its own authoritative DNS (and therefore **no load balancer**) | Accepted, refined by 0009 |
| [0005](0005-drop-aws-target.md) | Drop the AWS target | Accepted |
| [0006](0006-odd-node-count-3-to-35-round-robin-3-az.md) | Odd node count 3..35, round-robin over exactly 3 AZs | Accepted |
| [0007](0007-flex-auto-tiering-with-io1-raid0-and-rotational-fix.md) | Flex/Auto Tiering on 2× io1 with a udev `rotational=0` fix | Accepted |
| [0008](0008-poll-for-readiness-not-fixed-sleeps.md) | Poll for readiness rather than sleep | Accepted, **partially applied** |
| [0009](0009-two-exposure-modes-eval-and-production.md) | Two explicit exposure modes: `eval` and `production` | **Accepted 2026-09-21, not yet implemented** |
