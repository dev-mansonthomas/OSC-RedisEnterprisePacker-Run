# ADR 0001 — Bash + `oapi-cli` instead of Terraform/OpenTofu

**Status:** Accepted (2025-06 → today) · **re-affirmed 2026-09-21**

## Decision
All infrastructure is created, mutated and destroyed by hand-written bash scripts calling
`oapi-cli` (the Outscale API CLI) and parsing JSON with `jq`. No IaC tool is used.

## Evidence (VERIFIED)
- `osc/osc-setup.sh`, `osc/instanciate_image_outscale.sh`, `osc/tear_down_outscale.sh` —
  every resource is a raw `oapi-cli Create*/Delete*` call.
- No `*.tf`, `*.tofu`, CloudFormation or Ansible anywhere in the repo (`fd` over the tree).
- `README.md` lists `oapi-cli` + `jq` + bash 5 as the only prerequisites.

## Rationale (INFERRED)
Outscale's OAPI is AWS-shaped but not AWS; `oapi-cli` was the lowest-friction path and the
deliverable is a *demo/enablement* artifact a customer can read end-to-end in one sitting.
Bash also keeps the dependency surface at "things already on a Linux box".

## Consequences
- **Accepted:** zero toolchain to install, fully auditable by a customer, no state backend.
- **Cost:** no idempotency, no plan/diff, no dependency graph, no automatic rollback — all
  of which show up as concrete defects (`F-20`, `F-29`, `F-32`, `F-21`).
- An Outscale Terraform/OpenTofu provider exists and moving the network layer to it would
  delete `F-20`, `F-29`, `F-21` and `F-36` as a class.
  **Re-affirmed 2026-09-21 (maintainer): stay on bash.** Auditability by the customer is a
  *feature*, and "nothing to install" is a real constraint. Idempotency is to be fixed
  instead by porting Build's `build_scripts/lib/env_file.sh` (see `../tasks.md` F-20).
  Revisit only if deployment experience says otherwise.
