# ADR 0006 — Node count must be odd, 3..35; placement round-robins exactly 3 AZs

**Status:** Accepted (2025-09-10, commit `0ef36fc`)

## Decision
`cluster_instanciate.sh --nodes N` accepts only an **odd** integer with `3 ≤ N ≤ 35`, and
places node *i* in subnet/AZ `((i-1) mod 3) + 1`.

## Evidence (VERIFIED)
- `cluster_instanciate.sh:33-35` — `(( NODES < 3 || NODES > 35 || NODES % 2 == 0 ))` → exit 1.
  Confirmed by execution: `--nodes 4` and `--nodes 37` are both rejected.
- `cluster_instanciate.sh:71` — `rr_idx() { echo $(( ((i-1) % 3) + 1 )); }`.
- `osc-setup.sh:87` — the subnet loop is a literal `for i in 1 2 3`.
- Commit `0ef36fc`: *"refactor the code to be able to create any odd number of nodes between
  3 and 35 on outscale"*.

## Rationale
- **Odd** — VERIFIED as a Redis Enterprise requirement: quorum needs an odd node count to
  avoid split-brain.
- **3 minimum** — the smallest quorum-capable, rack-aware cluster.
- **35 maximum** — **INFERRED**: the largest cluster Redis Enterprise supports.
- **3 AZs** — matches `rack_aware` with `rack_id = subregion`, giving one-AZ-failure
  tolerance, and 3 is what `eu-west-2` offers.

## Consequences
- **Accepted:** invalid topologies are rejected before a single billable resource is created.
- **Cost:** the "3" is hardcoded in two independent places (`osc-setup.sh`'s subnet loop and
  `rr_idx`), so a region with 2 or 4 subregions needs edits in both (`F-30`).
- At N=35 the AZs hold 12/12/11 nodes — the split is uneven by construction, which is
  correct for quorum but means AZ capacity is not balanced.
