#!/bin/bash

# shellcheck source=.ibm/pipelines/utils.sh
source "$DIR"/utils.sh
# shellcheck source=.ibm/pipelines/install-methods/operator.sh
source "$DIR"/install-methods/operator.sh

gcloud_auth() {
  local service_account_name=$1
  local service_account_key_location=$2
  gcloud auth activate-service-account "${service_account_name}" --key-file "${service_account_key_location}"
}

gcloud_gke_get_credentials() {
  local cluster_name=$1
  local cluster_region=$2
  local project=$3
  gcloud container clusters get-credentials "${cluster_name}" --region "${cluster_region}" --project "${project}"
}

gcloud_ssl_cert_create() {
  local cert_name=$1
  local domain=$2
  local project=$3

  # Capture both stdout and stderr
  set +e
  local output
  output=$(gcloud compute ssl-certificates create "${cert_name}" --domains="${domain}" --project="${project}" --global 2>&1)
  set -e

  # Check the return status
  if [ $? -eq 0 ]; then
    echo "Certificate '${cert_name}' created successfully."
    echo "The test might fail if the certificate is not obtained from the certificate authority in time."
  else
    # Check if the error is due to certificate already existing
    if echo "$output" | grep -q "already exists"; then
      echo "Certificate '${cert_name}' already exists, continuing..."
    else
      echo "Error creating certificate '${cert_name}':"
      echo "$output"
      exit 1
    fi
  fi
}

cleanup_gke() {
  delete_tekton_pipelines
  uninstall_olm
  delete_rhdh_operator
}
