#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../_my_env.sh"
pause() {
  read -rp "Press any key to continue..." -n1
  echo    # retour à la ligne après la touche
}
# Valeurs par défaut
SUBNET_IDX=""
MACHINE_TYPE="tinav5.c2r4p3"    # specific machine type to outscale
FLEX_FLAG="flex"                # set to "" if you don't want flex
FLEX_SIZE_GB="40"               # 2 volumes in RAID0 of this size will be provisionned if FLEX_FLAG is set
VOLUME_TYPE="io1"               # gp2 (SSD), io1 (provisioned IOPS SSD)
FLEX_IOPS="${FLEX_IOPS:-1000}"  # IOPS per volume for io1 (min 100, max 64000 for AWS, 20000 for outscale, ratio 50 IOPS/GB) 

usage() {
  cat <<EOF
Usage: $0 --subnet <index> [--machine-type <type>] [--flex <sizeGB>]

Options:
  --node-num <num>        (obligatoire) node number (1, 2, 3, 4, 5, ...)
  --subnet <index>        (obligatoire) index du subnet (1, 2, 3)

Exemples:
  $0 --node-num 1 --subnet 1
  $0 --node-num 1 --subnet 2 
  $0 --node-num 1 --subnet 3 
EOF
}

# --- Parsing des arguments nommés ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-num)
      NODE_IDX="$2"
      shift 2
      ;;
    --subnet)
      SUBNET_IDX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Argument inconnu: $1"
      usage
      exit 1
      ;;
  esac
done

# --- Validation des paramètres ---

# --- Validation des paramètres ---
if [[ -z "$NODE_IDX" ]]; then
  echo "Error: --node-num <node_index> is mandatory."
  usage
  exit 1
fi

if [[ -z "$SUBNET_IDX" ]]; then
  echo "Error: --subnet <index> is mandatory."
  usage
  exit 1
fi

AMI_ID="${OUTSCALE_AMI_ID:-}"

echo "#########################################"
echo "# VM Instance Creation"
echo "#   Node Number  : ${NODE_IDX}"
echo "#   Subnet index : ${SUBNET_IDX}"
echo "#   Machine type : ${MACHINE_TYPE}"
echo "#   AMI/OMI ID   : ${AMI_ID}"

if [[ "$FLEX_FLAG" == "flex" ]]; then
  echo "#   Flex volumes : 2 x ${FLEX_SIZE_GB} GiB (type=${VOLUME_TYPE}, IOPS=${FLEX_IOPS})"
else
  echo "#   Flex volumes : none"
fi
echo "#########################################"

SECURITY_GROUP_ID="${OSC_SG_ID:-}"
SUBNET_ID_VAR="OSC_SUBNET${SUBNET_IDX}"
SUBNET_ID="${!SUBNET_ID_VAR}"
AZ_ID_VAR="OSC_AZ${SUBNET_IDX}"
AZ="${!AZ_ID_VAR}"
INSTANCE_NAME="redis-node-${NODE_IDX}"
OAPI_PROFILE="default"

if [[ -z "$AMI_ID"            ]]; then echo "Erreur: OUTSCALE_AMI_ID n'est pas défini";     exit 1; fi
if [[ -z "$SECURITY_GROUP_ID" ]]; then echo "Erreur: OSC_SG_ID n'est pas défini";               exit 1; fi
if [[ -z "$SUBNET_ID"         ]]; then echo "Erreur: ${SUBNET_ID_VAR} n'est pas défini";    exit 1; fi

# --- BlockDeviceMappings (FLEX -> 2 volumes io1) ---
BDM_JSON="[]"
if [[ "$FLEX_FLAG" == "flex" ]]; then
  # NOTE: io1 requiert un champ "Iops". Ajuste FLEX_IOPS selon la taille/perf souhaitée.

  BDM_JSON="$(
    jq -nc --arg size "$FLEX_SIZE_GB" --arg iops "$FLEX_IOPS" '
      [
        {
          "DeviceName": "/dev/sdf",
          "Bsu": {
            "VolumeSize": ($size|tonumber),
            "VolumeType": "io1",
            "Iops": ($iops|tonumber),
            "DeleteOnVmDeletion": true
          }
        },
        {
          "DeviceName": "/dev/sdg",
          "Bsu": {
            "VolumeSize": ($size|tonumber),
            "VolumeType": "io1",
            "Iops": ($iops|tonumber),
            "DeleteOnVmDeletion": true
          }
        }
      ]'
  )"
fi

echo "BlockDeviceMappings: $BDM_JSON"


VM_JSON=$(oapi-cli --profile "$OAPI_PROFILE" CreateVms \
  --ImageId "$OUTSCALE_AMI_ID" \
  --VmType "$MACHINE_TYPE" \
  --KeypairName "outscale-tmanson-keypair" \
  --SubnetId "$SUBNET_ID" \
  --Placement '{"Tenancy":"default","SubregionName":"'"$AZ"'"}' \
  --SecurityGroupIds '["'"$OSC_SG_ID"'"]' \
  --BlockDeviceMappings "$BDM_JSON"
)

echo "VM JSON Response: 
##########################
$VM_JSON
##########################
"

INSTANCE_ID=$(echo "$VM_JSON" | jq -r '.Vms[0].VmId')
echo "Instance ID: $INSTANCE_ID"

PUBLIC_IP=$(echo "$VM_JSON" | jq -r '.Vms[0].PublicIp')


echo "Allocated Public IP: $PUBLIC_IP"
echo "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/outscale-tmanson-keypair.rsa outscale@$PUBLIC_IP"
echo "Waiting for instance $INSTANCE_ID to pass status checks..."

get_state_vm=""
filter_json_st='{"VmIds":["'"$INSTANCE_ID"'"]}'
until [ "$get_state_vm" = "running" ] ; do
  sleep 3
  echo "[INFO][3s] - Waiting Vm ..."
  get_state_vm=$(oapi-cli ReadVmsState --Filters "$filter_json_st" \
                 | jq -r '.VmStates[].VmState')
  echo "Instance $INSTANCE_ID is '$get_state_vm'"
done
echo "Instance $INSTANCE_ID is now running."


# Ex: taguer les volumes de la VM
oapi-cli --profile "$OAPI_PROFILE" CreateTags \
         --ResourceIds '["'"$INSTANCE_ID"'"]' \
         --Tags '[{"Key":"Name","Value":"'"$INSTANCE_NAME"'"}]'


# Randomly get ssh connection refused after 15, 20 seconds, so instead I test if the ssh connection is ready
# --- SSH readiness wait ---
PUBLIC_IP="${PUBLIC_IP:?PUBLIC_IP manquant}"
SSH_USER="outscale"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ConnectionAttempts=1
)

MAX_WAIT="${MAX_WAIT:-600}"   # en secondes (10 min par défaut)
SLEEP_STEP="${SLEEP_STEP:-5}" # pause entre essais

echo "Waiting for SSH on ${PUBLIC_IP} (timeout ${MAX_WAIT}s)..."
start_ts=$(date +%s)
attempt=0
while true; do
  attempt=$((attempt + 1))
  # 1) Test TCP rapide via /dev/tcp (si dispo sur ce bash)
  if exec 3<>"/dev/tcp/${PUBLIC_IP}/22" 2>/dev/null; then
    exec 3>&- 3<&-
    # 2) Test d'un handshake SSH minimal (auth non interactive)
    if ssh "${SSH_OPTS[@]}" -i "$OUTSCALE_SSH_KEY" "${SSH_USER}@${PUBLIC_IP}" true 2>/dev/null; then
      echo "SSH is ready on ${PUBLIC_IP} after ${attempt} attempt(s)."
      break
    fi
  fi

  now_ts=$(date +%s)
  elapsed=$(( now_ts - start_ts ))
  if (( elapsed >= MAX_WAIT )); then
    echo "ERROR: SSH not ready on ${PUBLIC_IP} after ${elapsed}s."
    echo "Hints: check Security Group/ACL (port 22), route/NAT, public key and user '${SSH_USER}' are correct."
    exit 1
  fi

  printf "  ...not ready yet (attempt %d, elapsed %ds). Retrying in %ds...\n" "$attempt" "$elapsed" "$SLEEP_STEP"
  sleep "$SLEEP_STEP"
done
# --- end SSH readiness wait ---

# On sauvegarde aussi l'IP et l'ID dans ton _my_env.sh
echo -e "OUTSCALE_INSTANCE_PUBLIC_IP_${NODE_IDX}=${PUBLIC_IP} #${INSTANCE_ID}" >> "$(dirname "$0")/../_my_env.sh"