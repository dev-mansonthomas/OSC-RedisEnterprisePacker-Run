#!/usr/bin/env bash
# Détruit le CLUSTER (les VMs) en gardant le réseau Outscale intact :
# Net, Internet Service, route table, subnets et security group survivent.
#
# À utiliser entre deux itérations (nouvelle OMI, nouveau test), et
# OBLIGATOIREMENT quand le Net est partagé avec un autre projet — c'est le cas ici,
# le Net vient du repo OSC-RedisEnterprisePacker-Build.
# Pour tout détruire, y compris le réseau : ./tear_down_outscale.sh
#
# Cf. docs/tasks.md F-45 (raison d'être), F-36 (portée), F-21 (timeout + vérification),
#     F-20 (purge de l'état), F-15 (--profile partout).

set -euo pipefail                                    # avant le source (cf. F-12)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../_my_env.sh"
# shellcheck source=/dev/null
source "$ENV_FILE"

OAPI_PROFILE="${OAPI_PROFILE:-default}"

# ---------- Params ----------
ASSUME_YES=0
ALL_VMS=0          # 0 = seulement les VMs taguées redis-node-<n> par ce projet
KEEP_ENV=0
TIMEOUT="${TIMEOUT:-300}"

usage() {
  cat <<EOF
Usage: $0 [-y|--yes] [--all-vms] [--keep-env] [--timeout <sec>]

Supprime les VMs du Net \$OSC_NET_ID et conserve le réseau.

  -y, --yes         ne pas demander confirmation
      --all-vms     supprimer TOUTES les VMs du Net, pas seulement celles
                    taguées "redis-node-<n>" (dangereux sur un Net partagé)
      --keep-env    ne pas purger les OUTSCALE_INSTANCE_PUBLIC_IP_* de _my_env.sh
      --timeout N   attente max de la terminaison, en secondes (défaut: ${TIMEOUT})
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1; shift ;;
    --all-vms)    ALL_VMS=1; shift ;;
    --keep-env)   KEEP_ENV=1; shift ;;
    --timeout)    TIMEOUT="${2:?--timeout requiert une valeur}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Argument inconnu: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "Erreur: --timeout doit être un entier. Reçu: $TIMEOUT" >&2; exit 1
fi

: "${OSC_NET_ID:?OSC_NET_ID manquant dans _my_env.sh}"

NET_FILTER="{\"NetIds\":[\"$OSC_NET_ID\"]}"

echo "== Destruction du cluster (le réseau est conservé) =="
echo "Profile : $OAPI_PROFILE"
echo "Net     : $OSC_NET_ID"
echo "Portée  : $( ((ALL_VMS)) && echo 'TOUTES les VMs du Net' || echo 'VMs taguées redis-node-<n>' )"
echo "------------------------------------------------------"

# ---------- 1) Inventaire ----------
VMS_JSON="$(oapi-cli --profile "$OAPI_PROFILE" ReadVms --Filters "$NET_FILTER")"

if ((ALL_VMS)); then
  SELECT='.Vms[]'
else
  SELECT='.Vms[] | select(any(.Tags[]?; .Key=="Name" and (.Value|test("^redis-node-[0-9]+$"))))'
fi

# On ne garde que les VMs encore vivantes (une VM "terminated" n'a rien à supprimer).
VM_IDS=()
while IFS= read -r id; do
  [[ -n "$id" ]] && VM_IDS+=("$id")
done < <(echo "$VMS_JSON" | jq -r "$SELECT | select(.State != \"terminated\") | .VmId")

# Volumes rattachés, relevés AVANT suppression pour traquer les orphelins ensuite.
VOL_IDS=()
while IFS= read -r v; do
  [[ -n "$v" ]] && VOL_IDS+=("$v")
done < <(echo "$VMS_JSON" | jq -r "$SELECT | .BlockDeviceMappings[]?.Bsu.VolumeId // empty")

if [[ ${#VM_IDS[@]} -eq 0 ]]; then
  echo "Aucune VM à supprimer dans ce Net."
else
  echo "VMs qui vont être supprimées (${#VM_IDS[@]}) :"
  echo "$VMS_JSON" | jq -r "$SELECT | select(.State != \"terminated\")
    | \"  \(.VmId)  \(.State)  \(.PublicIp // \"-\")  \((.Tags[]?|select(.Key==\"Name\")|.Value) // \"-\")\""
  [[ ${#VOL_IDS[@]} -gt 0 ]] && echo "Volumes rattachés (${#VOL_IDS[@]}) : ${VOL_IDS[*]}"

  # ---------- 2) Confirmation ----------
  if ((! ASSUME_YES)); then
    printf "Confirmer la suppression ? [y/N] "
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "Annulé."; exit 1 ;;
    esac
  fi

  # ---------- 3) Suppression ----------
  IDS_JSON="$(printf '%s\n' "${VM_IDS[@]}" | jq -R . | jq -s -c .)"
  oapi-cli --profile "$OAPI_PROFILE" DeleteVms --VmIds "$IDS_JSON" >/dev/null
  echo "DeleteVms envoyé."

  # ---------- 4) Attente AVEC timeout (contrairement à tear_down_outscale.sh, cf. F-21) ----------
  echo "Attente de la terminaison (timeout ${TIMEOUT}s)..."
  start_ts=$(date +%s)
  while :; do
    remaining="$(oapi-cli --profile "$OAPI_PROFILE" ReadVms --Filters "$NET_FILTER" \
      | jq --argjson ids "$IDS_JSON" \
           '[.Vms[] | select(.VmId as $i | $ids | index($i)) | select(.State != "terminated")] | length')"
    [[ "$remaining" == "0" ]] && { echo "Toutes les VMs sont terminées."; break; }

    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= TIMEOUT )); then
      echo "ERREUR: ${remaining} VM(s) encore non terminée(s) après ${elapsed}s." >&2
      oapi-cli --profile "$OAPI_PROFILE" ReadVms --Filters "$NET_FILTER" \
        | jq -r '.Vms[] | select(.State != "terminated") | "  \(.VmId) \(.State)"' >&2
      exit 1
    fi
    printf "  ...%s restante(s) (%ss écoulées)\n" "$remaining" "$elapsed"
    sleep 5
  done
fi

# ---------- 5) Purge de l'état (cf. F-20) ----------
if ((KEEP_ENV)); then
  echo "--keep-env : _my_env.sh laissé tel quel."
else
  if grep -q '^OUTSCALE_INSTANCE_PUBLIC_IP_' "$ENV_FILE"; then
    cp -p "$ENV_FILE" "${ENV_FILE}.bak"
    # `>` dans le fichier existant : conserve inode et permissions (pas de mv)
    grep -v '^OUTSCALE_INSTANCE_PUBLIC_IP_' "${ENV_FILE}.bak" > "$ENV_FILE"
    echo "IPs de noeuds purgées de _my_env.sh (sauvegarde: $(basename "${ENV_FILE}").bak)"
  else
    echo "Aucune IP de noeud à purger dans _my_env.sh."
  fi
fi

# ---------- 6) Volumes orphelins (ils sont facturés) ----------
if [[ ${#VOL_IDS[@]} -gt 0 ]]; then
  VOLS_JSON="$(printf '%s\n' "${VOL_IDS[@]}" | jq -R . | jq -s -c .)"
  ORPHANS="$(oapi-cli --profile "$OAPI_PROFILE" ReadVolumes \
    --Filters "{\"VolumeIds\":$VOLS_JSON}" 2>/dev/null \
    | jq -r '.Volumes[]? | select(.State != "deleting") | "  \(.VolumeId) \(.Size)GB \(.State)"' || true)"
  if [[ -n "$ORPHANS" ]]; then
    echo "ATTENTION: volumes encore présents (facturés) :"
    echo "$ORPHANS"
    echo "Supprimer avec: oapi-cli --profile $OAPI_PROFILE DeleteVolume --VolumeId <id>"
  else
    echo "Aucun volume orphelin."
  fi
fi

# ---------- 7) Vérification finale : le réseau doit être intact ----------
echo "------------------------------------------------------"
kept=0
for pair in "Net:$OSC_NET_ID:ReadNets:NetIds:Nets" \
            "SecGroup:${OSC_SG_ID:-}:ReadSecurityGroups:SecurityGroupIds:SecurityGroups"; do
  IFS=: read -r label id call filter key <<<"$pair"
  [[ -n "$id" ]] || continue
  n="$(oapi-cli --profile "$OAPI_PROFILE" "$call" --Filters "{\"$filter\":[\"$id\"]}" \
       | jq -r "(.${key} // []) | length")"
  printf "  %-9s %-16s %s\n" "$label" "$id" "$( [[ "$n" == "1" ]] && echo 'conservé OK' || echo 'ABSENT !' )"
  [[ "$n" == "1" ]] || kept=1
done
if (( kept )); then
  echo "ERREUR: une ressource réseau attendue a disparu." >&2; exit 1
fi
echo "Cluster détruit, réseau conservé. Prêt pour ./cluster_instanciate.sh"
