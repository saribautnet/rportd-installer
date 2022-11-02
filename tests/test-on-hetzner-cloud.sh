#!/usr/local/bin/bash
#
# Script for semi-automated test if the rportd-installer.sh on a public cloud VM
# Requires hcloud command line tool https://github.com/hetznercloud/cli
#
set -e
cd "$(dirname $0)"

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  init
#   DESCRIPTION:  Do what is needed to get started
#    PARAMETERS:  ?
#       RETURNS:
#----------------------------------------------------------------------------------------------------------------------
init() {
  # Source your personal settings
  . .env
  # Generate a name for the VM
  curl 'https://randomuser.me/api/?inc=name&noinfo&nat=gb,us' -fs -o /tmp/.name
  VM_PREFIX=$(jq -r .results[0].name.first </tmp/.name)-$(jq -r .results[0].name.last </tmp/.name)
  VM_PREFIX=$(echo "${VM_PREFIX}" | tr '[:upper:]' '[:lower:]')
  rm -f /tmp/.name
  VM_NAME=${VM_PREFIX}
  export FQDN=$FQDN
  export VM_NAME=$VM_NAME
  export GODADDY_TLD=$GODADDY_TLD
}

create_installer() {
  (
    cd ..
    ./create_installer.sh
  )
}

create_update() {
  (
    cd ..
    ./create_update.sh
  )
}

copy_ssh_keys() {
  for FILE in $(find .ssh -type f -name "*.pub"); do
    echo Installing "$FILE"
    ssh-copy-id -f -i "$FILE" root@"$IP"
  done
}

create_vm() {
  # Set the OS Image
  if [ -z "$OS_IMAGE" ]; then
    OS_IMAGE=debian-11
  else
    if hcloud image list | grep -q $OS_IMAGE; then
      true
    else
      echo "Image $OS_IMAGE does not exist. Exit"
      false
    fi
  fi
  echo "🐧 Using Image ${OS_IMAGE}"

  # Create the VM on a random datacenter
  LOCATION=$(jot -r 1 1 3)
  loc[1]='Falkenstein eu-central'
  loc[2]='Nuremberg eu-central'
  loc[3]='Helsinki eu-central'
  loc[4]='Ashburn us-east'
  echo "🌎 VM will be created in ${loc[$LOCATION]}"
  echo "🚴 Creating VM ${VM_NAME} now ... "
  hcloud server create --type 1 --name "${VM_NAME}" --location "$LOCATION" --image ${OS_IMAGE} --ssh-key "${SSH_KEY}" >"$LOG_FILE"
  sleep 5
  IP=$(grep "^IPv4" "$LOG_FILE" | awk '{print $2}')
  echo "🚚 VM Created with IP address $IP"

  for i in $(seq 60); do
    ncat -w1 -z "${IP}" 22 && break
    sleep 1
    echo "$i" >/dev/null
  done
  export VM_ID=$VM_ID
  echo "IP=$IP" >.current_vm
  echo "VM_NAME=$VM_NAME" >>.current_vm
  copy_ssh_keys
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  create_random_fqdn
#   DESCRIPTION:  n.a.
#    PARAMETERS:  ?
#       RETURNS:
#----------------------------------------------------------------------------------------------------------------------
create_random_fqdn() {
  if [ -n "${GODADDY_TLD}" ]; then
    FQDN=${VM_NAME}.${GODADDY_TLD}
    echo "🏠 Creating DNS record ${FQDN} = ${IP} using daddy cli"
    daddy add -d "${GODADDY_TLD}" -t A -n "${VM_NAME}" -v "$IP"
    INSTALL_APPEND=$INSTALL_APPEND" --fqdn ${FQDN}"
    echo "FQDN: ${FQDN}" >>"$LOG_FILE"
    echo "FQDN=${FQDN}" >>.current_vm
    echo "⏳ Waiting for DNS record to be published ..."
    sleep 5
    for I in $(seq 1 20); do
      echo "(${I}) Checking DNS ..."
      if fqdn_is_public "${FQDN}"; then
        echo "🥳 FQDN $FQDN is now public."
        echo "Waiting for DNS to be fully propagated ..."
        sleep 5
        return 0
      else
        sleep 3
      fi
    done
    echo "👺 FQDN has not become public."
  fi
}

fqdn_is_public() {
  if curl -fs -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${1}" | grep -q '"Status":0'; then
    return 0
  else
    return 1
  fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  execute_installer
#   DESCRIPTION:  Execute the installer on the remote machine
#    PARAMETERS:  ?
#       RETURNS:
#----------------------------------------------------------------------------------------------------------------------
execute_installer() {
  echo "🖥️ executing 'bash rportd-installer.sh ${INSTALL_APPEND}' remotely now."
  if [ "$PUBLIC_SERVICE" -eq 0 ]; then
    echo "🏠 Using local installer script"
    test -e remote-out.log && rm -f remote-out.log
    ssh ${SSH_OPTS} "${IP}" "bash -s -- ${INSTALL_APPEND}" <../rportd-installer.sh | tee remote-out.log
  else
    echo "☁️ Using public installer script"
    cat <<EOF | ssh ${SSH_OPTS} "${IP}" bash
curl -JO https://get.rport.io
sudo bash rportd-installer.sh -v
sudo bash rportd-installer.sh ${INSTALL_APPEND}
EOF
  fi
  echo "IP=${IP}"
}

execute_update() {
  ssh ${SSH_OPTS} "${IP}" "bash -s -- -t" <../rportd-update.sh
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  do_tests
#   DESCRIPTION:  Do some basic tests
#    PARAMETERS:  ?
#       RETURNS:
#----------------------------------------------------------------------------------------------------------------------
do_tests() {
  ADMIN_PASSWORD=$(grep "Password =" remote-out.log | cut -d'=' -f2 | tr -d ' ')
  curl -fIv https://"${FQDN}"
  curl -fs https://"${FQDN}"/api/v1/login -u admin:"${ADMIN_PASSWORD}"
  echo ""
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  delete_vm
#   DESCRIPTION:  Delete the VM created before. Takes all data from the env
#    PARAMETERS:  ?
#       RETURNS:
#----------------------------------------------------------------------------------------------------------------------
delete_vm() {
  # Delete the VM
  VM_ID=$(grep "Server .* created" $LOG_FILE | awk '{print $2}')
  echo "💣 Deleting VM ${VM_NAME} [${VM_ID}]"
  hcloud server delete "$VM_ID"

  # Delete the FQDN
  . .current_vm
  if echo "$FDQN" | grep -q "${GODADDY_TLD}"; then
    echo "Deleting FQDN ${FQDN}"
    TLD=$(echo "$FQDN" | cut -d'.' -f2-3)
    NAME=$(echo "$FQDN" | cut -d'.' -f1)
    daddy remove -d "${TLD}" -t A -n "${NAME}" -f
    daddy show -d "${TLD}"
  fi

  FILES=(.current_vm cloud-test.log remote-out.log)
  for F in "${FILES[@]}"; do
    test -e "$F" && rm -f "$F"
  done
}

use_current_vm() {
  if [ -e .current_vm ]; then
    . ./.current_vm
    echo "♻️ Using current VM $VM_NAME $IP"
    fping "$IP"
    INSTALL_APPEND=$INSTALL_APPEND" --fqdn ${FQDN}"
  fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  help
#   DESCRIPTION:  print a help message
#    PARAMETERS:  ?
#       RETURNS:
#----------------------------------------------------------------------------------------------------------------------
help() {
  echo "
Usage $0 [OPTION(s)]

-h,--help show this help message
-r,--random-fqdn generate a random FQDN locally before executing the installer.
-i,--installer-args append string(s) to the rportd-installer.sh
-d,--delete-vm
-p,--public-service Use the public service get.rport.io instead of the locally generated scripts
-u,--update Update an existing VM with the rport-update.sh script
"
}

# parse options
TEMP=$(getopt \
  -o pdhrui: \
  --long help,public-service,random-fqdn,delete-vm,update,installer-args: \
  -- "$@")
eval set -- "$TEMP"
INSTALL_APPEND=""
RANDOM_FQDN=0
LOG_FILE="cloud-test.log"
PUBLIC_SERVICE=0
EXEC_UPDATE=0
SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -l root"

# extract options and their arguments into variables.
while true; do
  case "$1" in
  -h | --help)
    help
    exit 0
    ;;
  -r | --random-fqdn)
    RANDOM_FQDN=1
    shift 1
    ;;
  -i | --installer-args)
    INSTALL_APPEND="$2"
    shift 2
    ;;
  -d | --delete-vm)
    delete_vm
    exit 0
    ;;
  -p | --public-service)
    PUBLIC_SERVICE=1
    shift 1
    ;;
  -u | --update)
    EXEC_UPDATE=1
    shift 1
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Internal error!"
    help
    exit 1
    ;;
  esac
done

use_current_vm # Look for an existing VM
if [ -z "$VM_NAME" ]; then
  init
  create_vm
  if [ $RANDOM_FQDN -eq 1 ]; then create_random_fqdn; fi
fi
if [ $EXEC_UPDATE -eq 1 ]; then
  create_update
  execute_update
else
  create_installer
  execute_installer
fi
