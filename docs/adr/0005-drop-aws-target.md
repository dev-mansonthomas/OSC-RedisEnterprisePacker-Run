# ADR 0005 — Drop the AWS target

**Status:** Accepted (2025-09-29, commit `42cf32d`)

## Decision
AWS is no longer a supported target. Outscale is the only cloud.

## Evidence (VERIFIED)
- `git log --diff-filter=D --name-only` lists `aws/aws-setup.sh`, `aws/my_instanciate.sh`,
  `aws/instanciate_image_aws.sh`, `aws/teardown-aws-vpc.sh`,
  `aws/connect_to_my_instance.sh`, `packer/ubuntu_ufw_aws_image.pkr.hcl` as deleted.
- Commit `0ef36fc` (2025-09-10) explicitly says the N-node refactor is *"TBD for AWS"* — the
  AWS path was already lagging before it was removed.
- `34c7939` (2025-08-27) is the high-water mark for AWS: *"everything is working: build, aws
  setup, cluster instanciation"*.

## Rationale (VERIFIED from the project framing)
The deliverable is Redis Enterprise on **Outscale**, the French sovereign cloud. AWS was
scaffolding used to get the mechanics right on a familiar API before porting.

## Consequences
- **Accepted:** one code path to maintain and secure.
- **Cost:** `README.md` was written for the AWS-era layout and was never rewritten, so it
  documents eight paths that no longer exist (`R-05`). Anyone wanting AWS again must
  recover it from git history, where it is one refactor generation behind.
