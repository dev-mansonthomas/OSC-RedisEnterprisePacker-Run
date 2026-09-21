#!/usr/bin/env bash
# --- Chrono start ---
SECONDS=0

source "$(dirname "$0")/../_my_env.sh"
set -euo pipefail

# ---------- Params ----------
NODES=3
PARALLEL=0   # 0 = illimité, sinon limite le nombre de jobs en parallèle

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes) NODES="${2:-}"; shift 2 ;;
    --parallel) PARALLEL="${2:-0}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--nodes <odd between 3 and 35>] [--parallel <0|N>]

Default: --nodes 3, --parallel 0 (illimité)
AZ deployment: round-robin on 3 AZ/subnets (AZ1, AZ2, AZ3)
EOF
      exit 0
      ;;
    *) echo "Arg inconnu: $1"; exit 1 ;;
  esac
done

# ---------- Validation ----------
if ! [[ "$NODES" =~ ^[0-9]+$ ]]; then
  echo "Error: --nodes must be an integer. Got: $NODES"; exit 1
fi
if (( NODES < 3 || NODES > 35 || NODES % 2 == 0 )); then
  echo "Error: --nodes must be odd and 3 ≤ N ≤ 35. Got: $NODES"; exit 1
fi
if [[ -z "${AMI_ID:-}" && -z "${OUTSCALE_AMI_ID:-}" ]]; then
  echo "Error: AMI_ID/OUTSCALE_AMI_ID not set in _my_env.sh"; exit 1
fi

# ---------- Constantes / env ----------
SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
TARGET_SSH_KEY="${OUTSCALE_SSH_KEY}"

cluster_dns="${OUTSCALE_CLUSTER_DNS}"
RS_admin="${REDIS_LOGIN}"
RS_password="${REDIS_PWD}"

# Flex (udev + prepare_flash) – exécuté côté VM
FLE_CMD=""
if [[ "${FLEX_FLAG:-}" == "flex" ]]; then
  FLE_CMD=$(cat <<'EOF'
set -euo pipefail
# Force les disques à être reconnus comme SSD (rotational=0) au lieu de HDD (rotational=1).
# Utile pour le cloud Outscale où les volumes io1 peuvent être mal détectés par le kernel.
# Cette étape n'est pas forcément nécessaire sur d'autres clouds (AWS, Azure, GCP, etc.).
sudo tee /etc/udev/rules.d/99-rotational-fix.rules >/dev/null <<'RULES'
ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}="0"
ACTION=="add|change", KERNEL=="vd*", ATTR{queue/rotational}="0"
RULES
sudo udevadm control --reload
for d in /sys/block/sd* /sys/block/vd*; do
  [ -e "$d" ] && sudo udevadm trigger --action=change --sysname-match="$(basename "$d")"
done
# Préparation des disques Flash pour Redis Enterprise
sudo /opt/redislabs/sbin/prepare_flash.sh -y
EOF
)
fi

# ---------- Helpers ----------
rr_idx() { local i="$1"; echo $(( ((i-1) % 3) + 1 )); }

launch_node() {
  local node_idx="$1"
  local subnet_idx; subnet_idx="$(rr_idx "$node_idx")"
  ./instanciate_image_outscale.sh \
    --node-num "${node_idx}" \
    --subnet "${subnet_idx}"
}

configure_node() {
  local ip="$1" zone="$2" mode="$3" ord="$4" master_ip="${5:-}"
  scp $SSH_OPTS -i "$TARGET_SSH_KEY" \
    ../image_scripts/create-or-join-redis-cluster.sh \
    outscale@"$ip":/home/outscale/create-or-join-redis-cluster.sh

  ssh $SSH_OPTS -i "$TARGET_SSH_KEY" outscale@"$ip" <<EOF
  ${FLE_CMD:-true}
  chmod 700 /home/outscale/create-or-join-redis-cluster.sh
  sudo /home/outscale/create-or-join-redis-cluster.sh \
    "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$ip" "$zone" "$ord" ${master_ip:+"$master_ip"}
EOF
}

# Petit helper pour plafonner le parallélisme
wait_slot() {
  if (( PARALLEL > 0 )); then
    # Attends qu'il y ait moins de PARALLEL jobs actifs
    while (( $(jobs -r -p | wc -l) >= PARALLEL )); do
      # bash 5: wait -n (sinon attend un peu)
      if wait -n 2>/dev/null; then :; else sleep 0.2; fi
    done
  fi
}

# ---------- Déploiement ----------
declare -a NODE_IPS

# Node 1 (init) sur AZ1 (séquentiel, on initialise le cluster)
zone="${OSC_AZ1}"
echo ">>> Déploiement node 1 (init) sur AZ1..."
launch_node 1
# recharge l'env (IP master ajoutée par le script d'instanciation)
source "$(dirname "$0")/../_my_env.sh"
ip_master="${OUTSCALE_INSTANCE_PUBLIC_IP_1:?OUTSCALE_INSTANCE_PUBLIC_IP_1 manquante}"
NODE_IPS[1]="$ip_master"
configure_node "$ip_master" "$zone" "init" 1
echo "sleep 30 seconds to let the cluster initialize..."
sleep 30

# Instanciation + configuration en parallèle pour nodes 2..N
echo ">>> Instanciation + join en parallèle des nodes 2..$NODES..."
tmp_ips_file="$(mktemp)"
trap 'rm -f "$tmp_ips_file"' EXIT   # cf. docs/tasks.md F-11
pids=()
pid_nodes=()   # même index que pids -> n° de noeud, pour nommer les échecs (F-09)
for i in $(seq 2 "$NODES"); do
  wait_slot
  (
    # 1/ décalage initial
    sleep "$i"

    # 2/ instanciation
    idx="$(rr_idx "$i")"
    zone_var="OSC_AZ${idx}"
    zone="${!zone_var}"
    echo " -> [node $i] instanciation sur $zone_var..."
    launch_node "$i"

    # recharger l'env pour récupérer l'IP du node i
    source "$(dirname "$0")/../_my_env.sh"
    ip_var="OUTSCALE_INSTANCE_PUBLIC_IP_${i}"
    ip_i="${!ip_var:?$ip_var manquante}"

    # 2bis/ configuration immédiate (join)
    echo " -> [node $i] join sur $zone_var ($zone) IP=$ip_i..."
    configure_node "$ip_i" "$zone" "join" "$i" "$ip_master"
    echo " -> [node $i] join terminé."

    # enregistrer l'IP pour le récap final (dans le parent après wait)
    printf "%s %s\n" "$i" "$ip_i" >> "$tmp_ips_file"
  ) & pids+=("$!"); pid_nodes+=("$i")
done

# 3/ attendre la fin de tous les jobs parallèles.
# `wait` seul + `set -e` faisait avorter le script au PREMIER échec, sans dire lequel.
# `|| rc=$?` est exempt de `set -e`, donc on attend tout le monde et on sait exactement
# quels noeuds ont échoué avant de décider. Cf. docs/tasks.md F-09.
failed_nodes=()
for k in "${!pids[@]}"; do
  rc=0
  wait "${pids[$k]}" || rc=$?
  if (( rc != 0 )); then
    echo " !! [node ${pid_nodes[$k]}] ÉCHEC (exit $rc)"
    failed_nodes+=("${pid_nodes[$k]}")
  fi
done

# reconstruire NODE_IPS avec les IP collectées
while read -r idx ip; do
  NODE_IPS[idx]="$ip"
done < "$tmp_ips_file"

# ---------- Garde-fou : un noeud en échec = déploiement invalide ----------
if (( ${#failed_nodes[@]} > 0 )); then
  echo ""
  echo "###############################################################################"
  echo "ERREUR : ${#failed_nodes[@]} noeud(s) en échec : ${failed_nodes[*]}"
  echo "Le cluster est INCOMPLET. Ne pas considérer ce déploiement comme valide."
  echo ""
  echo "VMs créées (à inspecter puis nettoyer -- il n'y a pas de rollback automatique) :"
  for n in $(seq 1 "$NODES"); do
    [[ -n "${NODE_IPS[$n]:-}" ]] && echo "  node $n -> ${NODE_IPS[$n]}"
  done
  echo ""
  echo "Diagnostic sur un noeud en échec :"
  echo "  ssh $SSH_OPTS -i \"$TARGET_SSH_KEY\" outscale@<ip> \\"
  echo "    'sudo tail -50 /var/log/redis-enterprise-init.log; sudo journalctl -k | grep \"UFW BLOCK\" | tail -30'"
  echo "###############################################################################"
  exit 1
fi

# ---------- Récap DNS ----------
echo "
Configure your DNS with the following entries:
###############################################################################################"
# Enregistrements A pour chaque NS
for n in $(seq 1 "$NODES"); do
  [[ -n "${NODE_IPS[$n]:-}" ]] && echo "ns${n}.${OUTSCALE_CLUSTER_DNS}. 10800 IN A ${NODE_IPS[$n]}"
done

# Alias A pour le domaine principal
for n in "${!NODE_IPS[@]}"; do
  echo "${OUTSCALE_CLUSTER_DNS}. 10800 IN A ${NODE_IPS[$n]}"
done

# Enregistrements NS (autant que de nœuds)
for n in $(seq 1 "$NODES"); do
  echo "${OUTSCALE_CLUSTER_DNS}. 10800 IN NS ns${n}.${OUTSCALE_CLUSTER_DNS}."
done
echo "###############################################################################################"

# ---------- Vérification : c'est le CLUSTER qui doit confirmer, pas ce script ----------
echo ""
echo "Vérification du cluster via rladmin sur le node 1 ($ip_master)..."
rladmin_out="$(ssh $SSH_OPTS -i "$TARGET_SSH_KEY" outscale@"$ip_master" \
  'sudo /opt/redislabs/bin/rladmin status nodes' 2>&1 || true)"
actual_nodes="$(printf '%s\n' "$rladmin_out" | grep -oE 'node:[0-9]+' | sort -u | wc -l | tr -d ' ')"

if [[ "$actual_nodes" != "$NODES" ]]; then
  echo "###############################################################################"
  echo "ERREUR : le cluster déclare ${actual_nodes} noeud(s), ${NODES} attendu(s)."
  echo "Sortie brute de 'rladmin status nodes' :"
  printf '%s\n' "$rladmin_out" | sed 's/^/  /'
  echo "###############################################################################"
  exit 1
fi
echo "OK : le cluster déclare ${actual_nodes} noeud(s), comme demandé."
echo ""

echo "Cluster setup complete. Access your cluster at https://$cluster_dns:8443 with username $RS_admin."

# --- Chrono end ---
mins=$(( SECONDS / 60 ))
secs=$(( SECONDS % 60 ))
echo "Durée d'exécution : ${mins} minute(s) et ${secs} seconde(s)"