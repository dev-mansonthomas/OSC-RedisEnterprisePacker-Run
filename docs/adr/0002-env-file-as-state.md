# ADR 0002 — A sourced, append-only `_my_env.sh` is the only state

**Status:** Accepted · **contested**

## Decision
Configuration *and* generated resource IDs live in one gitignored shell file,
`_my_env.sh`. Scripts read it with `source` and write to it with `>>`.

## Evidence (VERIFIED)
- `source "$(dirname "$0")/../_my_env.sh"` at the top of all five `osc/` scripts.
- `osc-setup.sh:215-227` appends the `OSC_*` block; `instanciate_image_outscale.sh:220`
  appends `OUTSCALE_INSTANCE_PUBLIC_IP_<n>`.
- `cluster_instanciate.sh` re-`source`s the file mid-run (lines 114, 139) to pick up IPs
  written by a child process — the file is the IPC channel.
- `_my_env.template.sh` is the committed template; `.gitignore` excludes `_my_env.sh`.

## Rationale (INFERRED)
It is the simplest thing that gives child scripts and parallel subshells a shared
namespace without a real datastore, and a customer can inspect or hand-edit it.

## Consequences
- **Accepted:** trivially inspectable; `source` gives free `${VAR:-default}` and `${VAR:?}` ergonomics.
- **Cost:** append-only means duplicate keys after any re-run (`F-20`); teardown never
  prunes it; parallel writers are unsynchronised (`F-01`); and a config file that is also
  a *generated* file cannot be version-controlled or diffed.
- **Security cost:** `REDIS_PWD` sits in cleartext in a file that every script sources —
  see ADR 0004 and `F-06`.
- A split (`config.sh` committed-template + `state.json` generated, `jq`-managed) would fix
  most of this. Tracked as `F-20`.
