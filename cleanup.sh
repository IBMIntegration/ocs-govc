#!/usr/local/bin/bash

set -e

function deleteWebServerFiles() {
  THE_DIR=${WEBSERVER_WEBROOT}/${OPENSHIFT_CLUSTERNAME}
  if [[ -d ${THE_DIR} ]]; then
    echo "Removing web server cluster directory ${CLUSTER_DIR}"
    sudo rm -rf ${THE_DIR} 
  else
    echo "Web server cluster directory ${THE_DIR} does not exist"
  fi
}

function deleteBinaries() {

  THE_DIR="binaries"
  if [[ -d ${THE_DIR} ]]; then
    echo "Removing binaries directory ${PWD}/${THE_DIR}"
    rm -rf ${THE_DIR}
  else
    echo "Binaries directory ${PWD}/${THE_DIR} does not exist"
  fi
}

function deleteIso {

  THE_DIR="iso"
  if [[ -d ${THE_DIR} ]]; then
    echo "Removing iso directory ${PWD}/${THE_DIR}"
    rm -rf ${THE_DIR}
  else
    echo "iso directory ${PWD}/${THE_DIR} does not exist"
  fi
}


function deleteProjectClusterDirectory {

  THE_DIR="${OPENSHIFT_CLUSTERNAME}"
  if [[ -d "${THE_DIR}" ]]; then
    echo "Removing project cluster directory ${PWD}/${THE_DIR}"
    rm -rf ${THE_DIR}
  else
    echo "Project cluster directory ${PWD}/${THE_DIR} does not exist"
  fi
}

function deleteTempFiles {

  #Only required on Linux
  if [[ "${PLATFORM}" == "Linux" ]]; then
    THE_DIR="/tmp/tmpocpiso"
    if [[ -d ${THE_DIR} ]]; then
      echo "Removing ${THE_DIR}"
      sudo rm -rf ${THE_DIR}
    fi
  fi

  THE_FILE="/tmp/temp_isolinux.cfg"
  if [[  -f "${THE_FILE}"  ]]; then
    echo "Deleting ${THE_FILE}"
    sudo rm ${THE_FILE}
  else
    echo "${THE_FILE} does not exist"
  fi
}

function main() {
  deleteProjectClusterDirectory
  deleteWebServerFiles
  deleteBinaries
  deleteIso
  deleteTempFiles
}

. environment.properties

main