#!/bin/bash
# my new setting
CRC_BASE_DOMAIN=sec-test
#DOMAIN_MEM=14336
DOMAIN_MEM=24576
DOMAIN_VCPU=6
OPENSHIFT_VERSION=4.7.9
#OPENSHIFT_VERSION=latest-4.7

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

source tools.sh
source snc-library.sh

# kill all the child processes for this script when it exits
trap 'jobs=($(jobs -p)); [ -n "${jobs-}" ] && ((${#jobs})) && kill "${jobs[@]}" || true' EXIT

# If the user set OKD_VERSION in the environment, then use it to override OPENSHIFT_VERSION, MIRROR, and OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
# Unless, those variables are explicitly set as well.
OKD_VERSION=${OKD_VERSION:-none}
if [[ ${OKD_VERSION} != "none" ]]
then
    OPENSHIFT_VERSION=${OKD_VERSION}
    MIRROR=${MIRROR:-https://github.com/openshift/okd/releases/download}
fi

INSTALL_DIR=crc-tmp-install-data
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
CRC_PV_DIR="/mnt/pv-data"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp-dev-preview}
CERT_ROTATION=${SNC_DISABLE_CERT_ROTATION:-enabled}
HTPASSWD_FILE='users.htpasswd'

run_preflight_checks

# If user defined the OPENSHIFT_VERSION environment variable then use it.
# Otherwise use the tagged version if available
if test -n "${OPENSHIFT_VERSION-}"; then
    #OPENSHIFT_RELEASE_VERSION="$(curl -L "${MIRROR}"/${OPENSHIFT_VERSION}/release.txt | sed -n 's/^ *Version: *//p')"
    OPENSHIFT_RELEASE_VERSION=${OPENSHIFT_VERSION}
    echo "Using release ${OPENSHIFT_RELEASE_VERSION} from OPENSHIFT_VERSION"
else
    OPENSHIFT_RELEASE_VERSION="$(curl -L "${MIRROR}"/latest-4.8/release.txt | sed -n 's/^ *Version: *//p')"
    if test -n "${OPENSHIFT_RELEASE_VERSION}"; then
        echo "Using release ${OPENSHIFT_RELEASE_VERSION} from the latest mirror"
    else
        echo "Unable to determine an OpenShift release version.  You may want to set the OPENSHIFT_VERSION environment variable explicitly."
        exit 1
    fi
fi

# Download the oc binary for specific OS environment
download_oc
OC=./openshift-clients/linux/oc

if test -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE-}"; then
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/release.txt" | sed -n 's/^Pull From: //p')"
elif test -n "${OPENSHIFT_VERSION-}"; then
    echo "Both OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE and OPENSHIFT_VERSION are set, OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE will take precedence"
    echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
    echo "OPENSHIFT_VERSION: $OPENSHIFT_VERSION"
fi
echo "Setting OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# Extract openshift-install binary if not present in current directory
if test -z ${OPENSHIFT_INSTALL-}; then
    echo "Extracting OpenShift baremetal installer binary"
    ${OC} adm release -a ${OPENSHIFT_PULL_SECRET_PATH} extract ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --command=openshift-baremetal-install --to .
    OPENSHIFT_INSTALL=./openshift-baremetal-install
fi


# Allow to disable debug by setting SNC_OPENSHIFT_INSTALL_NO_DEBUG in the environment
if test -z "${SNC_OPENSHIFT_INSTALL_NO_DEBUG-}"; then
        OPENSHIFT_INSTALL_EXTRA_ARGS="--log-level debug"
else
        OPENSHIFT_INSTALL_EXTRA_ARGS=""
fi

# Destroy an existing cluster and resources
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} destroy cluster ${OPENSHIFT_INSTALL_EXTRA_ARGS} || echo "failed to destroy previous cluster.  Continuing anyway"
# Generate a new ssh keypair for this cluster
# Create a 521bit ECDSA Key
rm id_ecdsa_crc* || true
ssh-keygen -t ecdsa -b 521 -N "" -f id_ecdsa_crc -C "core"

# Use dnsmasq as dns in network manager config
if ! grep -iqR dns=dnsmasq /etc/NetworkManager/conf.d/ ; then
   cat << EOF | sudo tee /etc/NetworkManager/conf.d/crc-snc-nm-dnsmasq.conf
[main]
dns=dnsmasq
EOF
fi

# Clean up old DNS overlay file
if [ -f /etc/NetworkManager/dnsmasq.d/openshift.conf ]; then
    sudo rm /etc/NetworkManager/dnsmasq.d/openshift.conf
fi

# Set NetworkManager DNS overlay file
cat << EOF | sudo tee /etc/NetworkManager/dnsmasq.d/crc-snc.conf
server=/${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.1
address=/apps-${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.11
EOF

# Reload the NetworkManager to make DNS overlay effective
sudo systemctl reload NetworkManager


if [[ ${CERT_ROTATION} == "enabled" ]]
then
    # Disable the network time sync and set the clock to past (for a day) on host
    sudo timedatectl set-ntp off
    sudo date -s '-1 day'
fi

# Create the INSTALL_DIR for the installer and copy the install-config
rm -fr ${INSTALL_DIR} && mkdir ${INSTALL_DIR} && cp install-config.yaml ${INSTALL_DIR}
${YQ} eval --inplace ".compute[0].architecture = \"${yq_ARCH}\"" ${INSTALL_DIR}/install-config.yaml
${YQ} eval --inplace ".controlPlane.architecture = \"${yq_ARCH}\"" ${INSTALL_DIR}/install-config.yaml
${YQ} eval --inplace ".baseDomain = \"${BASE_DOMAIN}\"" ${INSTALL_DIR}/install-config.yaml
${YQ} eval --inplace ".metadata.name = \"${CRC_VM_NAME}\"" ${INSTALL_DIR}/install-config.yaml
${YQ} eval --inplace '.compute[0].replicas = 0' ${INSTALL_DIR}/install-config.yaml
replace_pull_secret ${INSTALL_DIR}/install-config.yaml
${YQ} eval ".sshKey = \"$(cat id_ecdsa_crc.pub)\"" --inplace ${INSTALL_DIR}/install-config.yaml

# Create the manifests using the INSTALL_DIR
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} create manifests

# Add CVO overrides before first start of the cluster. Objects declared in this file won't be created.
${YQ} eval-all --inplace 'select(fileIndex == 0) * select(filename == "cvo-overrides.yaml")' ${INSTALL_DIR}/manifests/cvo-overrides.yaml cvo-overrides.yaml

# Add custom domain to cluster-ingress
${YQ} eval --inplace ".spec.domain = \"apps-${CRC_VM_NAME}.${BASE_DOMAIN}\"" ${INSTALL_DIR}/manifests/cluster-ingress-02-config.yml
# Add master memory to 12 GB and 6 cpus 
# This is only valid for openshift 4.3 onwards
${YQ} eval --inplace '.spec.providerSpec.value.domainMemory = ${DOMAIN_MEM}' ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-0.yaml
${YQ} eval --inplace '.spec.providerSpec.value.domainVcpu = ${DOMAIN_VCPU}' ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-0.yaml
# Add master disk size to 31 GiB
# This is only valid for openshift 4.5 onwards
${YQ} eval --inplace '.spec.providerSpec.value.volume.volumeSize = 33285996544' ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-0.yaml
# Add network resource to lower the mtu for CNV
cp cluster-network-03-config.yaml ${INSTALL_DIR}/manifests/
# Add patch to mask the chronyd service on master
cp 99_master-chronyd-mask.yaml $INSTALL_DIR/openshift/
# Add dummy network unit file
cp 99-openshift-machineconfig-master-dummy-networks.yaml $INSTALL_DIR/openshift/
# Add codeReadyContainer as invoker to identify it with telemeter
export OPENSHIFT_INSTALL_INVOKER="codeReadyContainers"
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig

OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE ${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} create ignition-configs ${OPENSHIFT_INSTALL_EXTRA_ARGS}
# mask the chronyd service on the bootstrap node
cat <<< $(${JQ} '.systemd.units += [{"mask": true, "name": "chronyd.service"}]' ${INSTALL_DIR}/bootstrap.ign) > ${INSTALL_DIR}/bootstrap.ign

${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} create cluster ${OPENSHIFT_INSTALL_EXTRA_ARGS} || ${OC} adm must-gather --dest-dir ${INSTALL_DIR}

if [[ ${CERT_ROTATION} == "enabled" ]]
then
    renew_certificates
fi

# Wait for install to complete, this provide another 30 mins to make resources (apis) stable
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} wait-for install-complete ${OPENSHIFT_INSTALL_EXTRA_ARGS}

# Set the VM static hostname to crc-xxxxx-master-0 instead of localhost.localdomain
HOSTNAME=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} hostnamectl status --transient)
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} sudo hostnamectl set-hostname ${HOSTNAME}

create_json_description

# Create persistent volumes
create_pvs "${CRC_PV_DIR}" 30

# Mark some of the deployments unmanaged by the cluster-version-operator (CVO)
# https://github.com/openshift/cluster-version-operator/blob/master/docs/dev/clusterversion.md#setting-objects-unmanaged
# Objects declared in this file are still created by the CVO at startup.
# The CVO won't modify these objects anymore with the following command. Hence, we can remove them afterwards.
retry ${OC} patch clusterversion version --type json -p "$(cat cvo-overrides-after-first-run.yaml)"

# Clean-up 'openshift-machine-api' namespace
delete_operator "deployment/machine-api-operator" "openshift-machine-api" "k8s-app=machine-api-operator"
retry ${OC} delete statefulset,deployment,daemonset --all -n openshift-machine-api
retry ${OC} delete clusteroperator machine-api

# Clean-up 'openshift-machine-config-operator' namespace
delete_operator "deployment/machine-config-operator" "openshift-machine-config-operator" "k8s-app=machine-config-operator"
retry ${OC} delete statefulset,deployment,daemonset --all -n openshift-machine-config-operator
retry ${OC} delete clusteroperator machine-config

# Scale route deployment from 2 to 1
retry ${OC} scale --replicas=1 ingresscontroller/default -n openshift-ingress-operator

# Set default route for registry CRD from false to true.
retry ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

# Generate the htpasswd file to have admin and developer user
generate_htpasswd_file ${INSTALL_DIR} ${HTPASSWD_FILE}

# Add a user developer with htpasswd identity provider and give it sudoer role
# Add kubeadmin user with cluster-admin role
retry ${OC} create secret generic htpass-secret --from-file=htpasswd=${HTPASSWD_FILE} -n openshift-config
retry ${OC} apply -f oauth_cr.yaml
retry ${OC} create clusterrolebinding kubeadmin --clusterrole=cluster-admin --user=kubeadmin

# Remove temp kubeadmin user
retry ${OC} delete secrets kubeadmin -n kube-system

# Replace pull secret with a null json string '{}'
retry ${OC} replace -f pull-secret.yaml

# Remove the Cluster ID with a empty string.
retry ${OC} patch clusterversion version -p '{"spec":{"clusterID":""}}' --type merge

# Remove machineconfigs(mc) and machineconfigpools(mcp)
retry ${OC} delete machineconfigs --all
retry ${OC} delete machineconfigpools --all

# SCP the kubeconfig file to VM
${SCP} ${KUBECONFIG} core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/home/core/
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo mv /home/core/kubeconfig /opt/'

# Export all manifests to the disk, modify them and use them in the CVO
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo mkdir /opt/release-manifests/'
CVO_POD_NAME=$(${OC} -n openshift-cluster-version get pods -o=name)
retry ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- "sudo KUBECONFIG=/opt/kubeconfig oc rsync -n openshift-cluster-version ${CVO_POD_NAME}:/release-manifests/ /opt/release-manifests/"
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo sed -i "s/replicas: 2/replicas: 1/" /opt/release-manifests/*deployment.yaml'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo sed -i "s/replicas: 2/replicas: 1/" /opt/release-manifests/*clusterserviceversion.yaml'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo sed -i "/memory: /d" /opt/release-manifests/*deployment.yaml'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo sed -i "/memory: /d" /opt/release-manifests/*deploy.yaml'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo sed -i "/memory: /d" /opt/release-manifests/*operator.yaml'
${OC} -n openshift-cluster-version patch deploy cluster-version-operator --type=json -p=$(cat custom-release.json | jq -c .)

# Wait for the cluster again to become stable because of all the patches/changes
wait_till_cluster_stable

# Delete the pods which are there in Complete state
retry ${OC} delete pod --field-selector=status.phase==Succeeded --all-namespaces
