#!/usr/bin/bash

set -e
set -u

function download_binaries() {

  test -e binaries || mkdir binaries
  test -e ${OPENSHIFT_CLUSTERNAME} || mkdir ${OPENSHIFT_CLUSTERNAME}
  echo "Downloading GOVC"
  curl -sL -o binaries/govc.gz ${BINARIES_GOVC}
  gunzip binaries/govc.gz
  chmod 755 binaries/govc

  echo "Downloading OpenShift ISO"
  curl -sL -o binaries/installer.iso ${BINARIES_ISO}

  echo "Downloading OpenShift BIOS"
  curl -sL -o ${OPENSHIFT_CLUSTERNAME}/bios.gz ${BINARIES_BIOS}

  echo "Downloading OpenShift Installer"
  curl -sL -o binaries/installer.tar.gz ${BINARIES_INSTALLER}
  tar -xf binaries/installer.tar.gz -C binaries
  rm binaries/installer.tar.gz

  echo "Downloading OpenShift Client"
  curl -sL -o binaries/client.tar.gz ${BINARIES_CLIENT}
  tar -xf binaries/client.tar.gz -C binaries
  rm binaries/client.tar.gz
  rm binaries/README.md
}

function extract_iso() {
  test -e iso || mkdir iso
  PLATFORM=$(uname -s)
  if [[ "${PLATFORM}" == "Darwin" ]]; then
    echo "Mounting ISO"
    MOUNTPOINT=$(hdiutil mount binaries/installer.iso | awk '{print $2}')
    echo "Copying ISO files"
    cp -r "${MOUNTPOINT}"/* iso/
    echo "Unmounting ISO"
    hdiutil unmount "$MOUNTPOINT" >/dev/null
  elif [[ "${PLATFORM}" == "Linux" ]]; then
    test -e /tmp/tmpocpiso || mkdir /tmp/tmpocpiso
    echo "Mounting ISO"
    sudo mount binaries/installer.iso /tmp/tmpocpiso >/dev/null
    echo "Copying ISO files"
    cp -r /tmp/tmpocpiso/* iso/
    echo "Unmounting ISO"
    sudo umount /tmp/tmpocpiso >/dev/null
  fi
  chmod -R u+w iso/
}

function create_iso() {
  IP=${1}
  HOSTNAME=${2}
  TYPE=${3}

  NS=""
  for ns in ${NETWORK_NAMESERVERS[@]}; do
    NS="${NS} nameserver=$ns"
  done

  echo "Creating bootable ISO for ${HOSTNAME}"

  cat /tmp/temp_isolinux.cfg | sed "s/coreos.inst=yes/coreos.inst=yes ip=$IP::${NETWORK_GATEWAY}:${NETWORK_NETMASK}:${HOSTNAME}:${NETWORK_DEVICE}:none ${NS} coreos.inst.install_dev=sda coreos.inst.image_url=http:\/\/${WEBSERVER_EXTERNAL_IP}:${WEBSERVER_PORT}\/${OPENSHIFT_CLUSTERNAME}\/bios.gz coreos.inst.ignition_url=http:\/\/${WEBSERVER_EXTERNAL_IP}:${WEBSERVER_PORT}\/${OPENSHIFT_CLUSTERNAME}\/${TYPE}.ign/" >iso/isolinux/isolinux.cfg

  mkisofs -o binaries/${HOSTNAME}.iso \
    -rational-rock -J -joliet-long -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 \
    -boot-info-table iso/ >/dev/null 2>&1

  echo "Uploading ${HOSTNAME}.iso to vSphere"
  binaries/govc datastore.upload \
    -ds="${VSPHERE_IMAGE_DATASTORE}" \
    binaries/${HOSTNAME}.iso \
    "${VSPHERE_IMAGE_DATASTORE_PATH}/${HOSTNAME}.iso" >/dev/null
}

function create_all_isos() {

  test -e /tmp/temp_isolinux.cfg || {
    echo "Copying original isolinux.cfg file to /tmp/temp_isolinux.cfg"
    cat iso/isolinux/isolinux.cfg | sed 's/default vesamenu.c32/default linux/g' >/tmp/temp_isolinux.cfg
  }
  which mkisofs >/dev/null || {
    echo "Unable to find mkisofs.  Please install it for your platform and re-run script"
    echo "macOS: brew install cdrtools"
    echo "linux: install genisoimage package"
    exit 1
  }

  create_iso ${BOOTSTRAP_IPADDRESS} ${BOOTSTRAP_HOSTNAME} "bootstrap"

  for i in ${!MASTER_HOSTNAME[@]}; do
    let c=$i+1
    if [ $c -gt ${MASTER_COUNT} ]; then
      break
    fi
    create_iso "${MASTER_IPADDRESS[$i]}" "${MASTER_HOSTNAME[$i]}" "master"
  done

  for i in ${!WORKER_HOSTNAME[@]}; do
    let c=$i+1
    if [ $c -gt ${WORKER_COUNT} ]; then
      break
    fi
    create_iso "${WORKER_IPADDRESS[$i]}" "${WORKER_HOSTNAME[$i]}" "worker"
  done

  if [[ "${STORAGE_COUNT}" -gt "0" ]]; then
    for i in ${!STORAGE_HOSTNAME[@]}; do
      let c=$i+1
      if [ $c -gt ${STORAGE_COUNT} ]; then
        break
      fi
      create_iso "${STORAGE_IPADDRESS[$i]}" "${STORAGE_HOSTNAME[$i]}" "worker"
    done
  fi

}

function create_ignition_configs() {
  echo "starting ${OPENSHIFT_CLUSTERNAME}"
  test -e ${OPENSHIFT_CLUSTERNAME} || mkdir ${OPENSHIFT_CLUSTERNAME}
  test -e "${OPENSHIFT_SSHKEY}.pub" || ssh-keygen -t rsa -b 4096 -N '' -f ${OPENSHIFT_SSHKEY}
  cat <<EOF >${OPENSHIFT_CLUSTERNAME}/install-config.yaml
apiVersion: v1
baseDomain: ${OPENSHIFT_BASEDOMAIN}
proxy:
  httpProxy: ${HTTP_PROXY}
  httpsProxy: ${HTTPS_PROXY}
  noProxy: ${NO_PROXY}
compute:
- hyperthreading: Enabled
  name: worker
  replicas: ${WORKER_COUNT}
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: ${MASTER_COUNT}
metadata:
  name: ${OPENSHIFT_CLUSTERNAME}
networking:
  clusterNetworks:
  - cidr: ${OPENSHIFT_CLUSTERCIDR}
    hostPrefix: ${OPENSHIFT_HOSTPREFIX}
  networkType: OpenShiftSDN
  serviceNetwork:
  - ${OPENSHIFT_SERVICECIDR}
platform:
  vsphere:
    vCenter: ${VSPHERE_HOSTNAME}
    username: ${VSPHERE_USERNAME}
    password: ${VSPHERE_PASSWORD}
    datacenter: ${VSPHERE_DATACENTER}
    defaultDatastore: ${VSPHERE_NODE_DATASTORE}
pullSecret: '$(<${OPENSHIFT_PULLSECRET})'
sshKey: '$(<"${OPENSHIFT_SSHKEY}.pub")'
EOF
  cp ${OPENSHIFT_CLUSTERNAME}/install-config.yaml ${OPENSHIFT_CLUSTERNAME}/install-config-backup.yaml
  binaries/openshift-install --dir=${OPENSHIFT_CLUSTERNAME} create ignition-configs
}

function copy_files_to_webroot() {
  chmod 644 ${OPENSHIFT_CLUSTERNAME}/*.ign ${OPENSHIFT_CLUSTERNAME}/bios.gz
  ifconfig -a | grep ${WEBSERVER_INTERNAL_IP} >/dev/null && {
    test -e ${WEBSERVER_WEBROOT}/${OPENSHIFT_CLUSTERNAME} || mkdir ${WEBSERVER_WEBROOT}/${OPENSHIFT_CLUSTERNAME}
    cp -Rp ${OPENSHIFT_CLUSTERNAME}/*.ign ${OPENSHIFT_CLUSTERNAME}/bios.gz ${WEBSERVER_WEBROOT}/${OPENSHIFT_CLUSTERNAME}
  } || {
    scp -i ${WEBSERVER_SSHKEY} -r ${OPENSHIFT_CLUSTERNAME} ${WEBSERVER_USERNAME}@${WEBSERVER_EXTERNAL_IP}:${WEBSERVER_WEBROOT}
  }
}

function create_vm() {
  set -x

  CPU=$1
  MEM=$2
  DISK=$3
  HOSTNAME=$4

  let "MEM=$MEM*1024"
  FOLDER="/${VSPHERE_DATACENTER}/vm/${VSPHERE_FOLDER}"
  binaries/govc vm.create \
    -c=${CPU} \
    -m=${MEM} \
    -disk=${DISK}GB \
    -ds="${VSPHERE_NODE_DATASTORE}" \
    -net="${VSPHERE_NETWORK}" \
    -net.adapter=vmxnet3 \
    -disk.controller=pvscsi \
    -pool="${VSPHERE_POOL}" \
    -folder="${FOLDER}" \
    -on=false \
    -iso-datastore="${VSPHERE_IMAGE_DATASTORE}" \
    -iso="${VSPHERE_IMAGE_DATASTORE_PATH}/${HOSTNAME}.iso" \
    ${HOSTNAME}

  binaries/govc vm.change \
    -e disk.enableUUID=1 \
    -vm "${FOLDER}/${HOSTNAME}"

  binaries/govc vm.power -on=true "${FOLDER}/${HOSTNAME}"

}

function create_all_vms() {

  set -x
  #The Bootstrap node
  create_vm "${BOOTSTRAP_CPU}" "${BOOTSTRAP_MEM}" "${BOOTSTRAP_DISK}" ${BOOTSTRAP_HOSTNAME}

  for i in ${!MASTER_HOSTNAME[@]}; do
    let c=$i+1
    if [[ $c -gt ${MASTER_COUNT} ]]; then
      break
    fi
    create_vm ${MASTER_CPU} ${MASTER_MEM} ${MASTER_DISK} ${MASTER_HOSTNAME[$i]}
  done

  for i in ${!WORKER_HOSTNAME[@]}; do
    let c=$i+1
    if [[ $c -gt ${WORKER_COUNT} ]]; then
      break
    fi
    create_vm ${WORKER_CPU} ${WORKER_MEM} ${WORKER_DISK} ${WORKER_HOSTNAME[$i]}
  done

  if [[ "${STORAGE_COUNT}" -gt "0" ]]; then
    for i in ${!STORAGE_HOSTNAME[@]}; do
      let c=$i+1
      if [[ $c -gt ${STORAGE_COUNT} ]]; then
        break
      fi
      create_vm ${STORAGE_CPU} ${STORAGE_MEM} ${STORAGE_DISK} ${STORAGE_HOSTNAME[$i]}
    done
  fi
}

function wait_for_cluster() {
  FOLDER="/${VSPHERE_DATACENTER}/vm/${VSPHERE_FOLDER}"
  binaries/openshift-install --dir="${OPENSHIFT_CLUSTERNAME}" wait-for bootstrap-complete --log-level debug
  #binaries/govc vm.destroy /"${FOLDER}/${BOOTSTRAP_HOSTNAME}"
  binaries/openshift-install --dir="${OPENSHIFT_CLUSTERNAME}" wait-for install-complete
}

function configure_storage() {
  if [[ "${STORAGE_COUNT}" -gt "0" ]]; then
    for i in $(eval echo {1..${STORAGE_COUNT}}); do
      let "c=i-1"
      oc adm taint node ${STORAGE_HOSTNAME[$c]}.${OPENSHIFT_CLUSTERNAME}.${OPENSHIFT_BASEDOMAIN} node.ocs.openshift.io/storage=true:NoSchedule
      oc label node ${STORAGE_HOSTNAME[$c]}.${OPENSHIFT_CLUSTERNAME}.${OPENSHIFT_BASEDOMAIN} cluster.ocs.openshift.io/openshift-storage=
    done
    cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: openshift-storage
spec: {}
EOF
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  serviceAccount:
    metadata:
      creationTimestamp: null
  targetNamespaces:
  - openshift-storage
EOF
    OCS_VERSION=$(oc get packagemanifests -n openshift-marketplace ocs-operator -o template --template '{{range .status.channels}}{{.currentCSVDesc.version}}{{end}}' | tail -1)
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ocs-operator
  namespace: openshift-storage
spec:
  channel: stable-4.2
  installPlanApproval: Automatic
  name: ocs-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: ocs-operator.v${OCS_VERSION}
EOF
    while ! oc api-resources | grep StorageCluster$ >/dev/null; do
      echo "Waiting for StorageCluster CRD"
      sleep 10
    done
    cat <<EOF | oc create -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  manageNodes: false
  storageDeviceSets:
    - count: 1
      dataPVCTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 2Ti
          storageClassName: null
          volumeMode: Block
      name: ocs-deviceset
      placement: {}
      portable: true
      replica: 3
      resources: {}
EOF
    cat <<EOF | oc create -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ${CLOUDPAK_STORAGECLASS_FILE}
EOF
    oc patch config cluster --type merge --patch '{"spec": {"managementState": "Managed", "replicas": 2, "storage": {"pvc": {"claim": ""}}}}'
  fi
}


source ./environment.properties

export GOVC_URL=${VSPHERE_HOSTNAME}
export GOVC_USERNAME=${VSPHERE_USERNAME}
export GOVC_PASSWORD=${VSPHERE_PASSWORD}
export GOVC_INSECURE=${VSPHERE_INSECURE}
export GOVC_DATASTORE=${VSPHERE_IMAGE_DATASTORE}
export KUBECONFIG=$PWD/${OPENSHIFT_CLUSTERNAME}/auth/kubeconfig

download_binaries
extract_iso
create_all_isos
create_ignition_configs
copy_files_to_webroot
create_all_vms
wait_for_cluster
configure_storage
