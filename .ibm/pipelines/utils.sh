#!/bin/bash

# shellcheck source=.ibm/pipelines/reporting.sh
source "${DIR}/reporting.sh"

retrieve_pod_logs() {
  local pod_name=$1; local container=$2; local namespace=$3
  echo "  Retrieving logs for container: $container"
  # Save logs for the current and previous container
  kubectl logs $pod_name -c $container -n $namespace > "pod_logs/${pod_name}_${container}.log" || { echo "  logs for container $container not found"; }
  kubectl logs $pod_name -c $container -n $namespace --previous > "pod_logs/${pod_name}_${container}-previous.log" 2>/dev/null || { echo "  Previous logs for container $container not found"; rm -f "pod_logs/${pod_name}_${container}-previous.log"; }
}

save_all_pod_logs(){
  set +e
  local namespace=$1
  rm -rf pod_logs && mkdir -p pod_logs

  # Get all pod names in the namespace
  pod_names=$(kubectl get pods -n $namespace -o jsonpath='{.items[*].metadata.name}')
  for pod_name in $pod_names; do
    echo "Retrieving logs for pod: $pod_name in namespace $namespace"

    init_containers=$(kubectl get pod $pod_name -n $namespace -o jsonpath='{.spec.initContainers[*].name}')
    # Loop through each init container and retrieve logs
    for init_container in $init_containers; do
      retrieve_pod_logs $pod_name $init_container $namespace
    done

    containers=$(kubectl get pod $pod_name -n $namespace -o jsonpath='{.spec.containers[*].name}')
    for container in $containers; do
      retrieve_pod_logs $pod_name $container $namespace
    done
  done

  mkdir -p "${ARTIFACT_DIR}/${namespace}/pod_logs"
  cp -a pod_logs/* "${ARTIFACT_DIR}/${namespace}/pod_logs"
  set -e
}

droute_send() {
  if [[ "${OPENSHIFT_CI}" != "true" ]]; then return 0; fi
  if [[ "${JOB_NAME}" == *rehearse* ]]; then return 0; fi
  local original_context
  original_context=$(oc config current-context) # Save original context
  echo "Saving original context: $original_context"
  ( # Open subshell
    set +e
    local droute_version="1.2.2"
    local release_name=$1
    local project=$2
    local droute_project="droute"
    local metadata_output="data_router_metadata_output.json"

    oc config set-credentials temp-user --token="${RHDH_PR_OS_CLUSTER_TOKEN}"
    oc config set-cluster temp-cluster --server="${RHDH_PR_OS_CLUSTER_URL}"
    oc config set-context temp-context --user=temp-user --cluster=temp-cluster
    oc config use-context temp-context
    oc whoami --show-server
    trap 'oc config use-context "$original_context"' RETURN

    # Ensure that we are only grabbing the last matched pod
    local droute_pod_name=$(oc get pods -n droute --no-headers -o custom-columns=":metadata.name" | grep ubi9-cert-rsync | awk '{print $1}' | tail -n 1)
    local temp_droute=$(oc exec -n "${droute_project}" "${droute_pod_name}" -- /bin/bash -c "mktemp -d")

    ARTIFACTS_URL=$(get_artifacts_url)
    JOB_URL=$(get_job_url)

    # Remove properties (only used for skipped test and invalidates the file if empty)
    sed_inplace '/<properties>/,/<\/properties>/d' "${ARTIFACT_DIR}/${project}/${JUNIT_RESULTS}"
    # Replace attachments with link to OpenShift CI storage
    sed_inplace "s#\[\[ATTACHMENT|\(.*\)\]\]#${ARTIFACTS_URL}/\1#g" "${ARTIFACT_DIR}/${project}/${JUNIT_RESULTS}"

    jq \
      --arg hostname "$REPORTPORTAL_HOSTNAME" \
      --arg project "$DATA_ROUTER_PROJECT" \
      --arg name "$JOB_NAME" \
      --arg description "[View job run details](${JOB_URL})" \
      --arg key1 "job_type" \
      --arg value1 "$JOB_TYPE" \
      --arg key2 "pr" \
      --arg value2 "$GIT_PR_NUMBER" \
      --arg key3 "job_name" \
      --arg value3 "$JOB_NAME" \
      --arg key4 "tag_name" \
      --arg value4 "$TAG_NAME" \
      --arg auto_finalization_treshold $DATA_ROUTER_AUTO_FINALIZATION_TRESHOLD \
      '.targets.reportportal.config.hostname = $hostname |
      .targets.reportportal.config.project = $project |
      .targets.reportportal.processing.launch.name = $name |
      .targets.reportportal.processing.launch.description = $description |
      .targets.reportportal.processing.launch.attributes += [
          {"key": $key1, "value": $value1},
          {"key": $key2, "value": $value2},
          {"key": $key3, "value": $value3},
          {"key": $key4, "value": $value4}
        ] |
      .targets.reportportal.processing.tfa.auto_finalization_threshold = ($auto_finalization_treshold | tonumber)
      ' data_router/data_router_metadata_template.json > "${ARTIFACT_DIR}/${project}/${metadata_output}"

    # Send test by rsync to bastion pod.
    local max_attempts=5
    local wait_seconds_step=1
    for ((i = 1; i <= max_attempts; i++)); do
      echo "Attempt ${i} of ${max_attempts} to rsync test resuls to bastion pod."
      if output=$(oc rsync --progress=true --include="${metadata_output}" --include="${JUNIT_RESULTS}" --exclude="*" -n "${droute_project}" "${ARTIFACT_DIR}/${project}/" "${droute_project}/${droute_pod_name}:${temp_droute}/" 2>&1); then
        echo "$output"
        save_status_data_router_failed "$CURRENT_DEPLOYMENT" false
        break
      elif ((i == max_attempts)); then
        echo "Failed to rsync test results after ${max_attempts} attempts."
        echo "Last rsync error details:"
        echo "${output}"
        echo "Troubleshooting steps:"
        echo "1. Restart $droute_pod_name in $droute_project project/namespace"
        save_status_data_router_failed "$CURRENT_DEPLOYMENT" true
        return
      else
        sleep $((wait_seconds_step * i))
      fi
    done

    # "Install" Data Router
    oc exec -n "${droute_project}" "${droute_pod_name}" -- /bin/bash -c "
      curl -fsSLk -o ${temp_droute}/droute-linux-amd64 'https://${DATA_ROUTER_NEXUS_HOSTNAME}/nexus/repository/dno-raw/droute-client/${droute_version}/droute-linux-amd64' \
      && chmod +x ${temp_droute}/droute-linux-amd64 \
      && ${temp_droute}/droute-linux-amd64 version"

    # Send test results through DataRouter and save the request ID.
    local max_attempts=10
    local wait_seconds_step=1
    for ((i = 1; i <= max_attempts; i++)); do
      echo "Attempt ${i} of ${max_attempts} to send test results through Data Router."
      if output=$(oc exec -n "${droute_project}" "${droute_pod_name}" -- /bin/bash -c "
        ${temp_droute}/droute-linux-amd64 send --metadata ${temp_droute}/${metadata_output} \
          --url '${DATA_ROUTER_URL}' \
          --username '${DATA_ROUTER_USERNAME}' \
          --password '${DATA_ROUTER_PASSWORD}' \
          --results '${temp_droute}/${JUNIT_RESULTS}' \
          --verbose" 2>&1) && \
        DATA_ROUTER_REQUEST_ID=$(echo "$output" | grep "request:" | awk '{print $2}') &&
        [ -n "$DATA_ROUTER_REQUEST_ID" ]; then
        echo "Test results successfully sent through Data Router."
        echo "Request ID: $DATA_ROUTER_REQUEST_ID"
        break
      elif ((i == max_attempts)); then
        echo "Failed to send test results after ${max_attempts} attempts."
        echo "Last Data Router error details:"
        echo "${output}"
        echo "Troubleshooting steps:"
        echo "1. Restart $droute_pod_name in $droute_project project/namespace"
        echo "2. Check the Data Router documentation: https://spaces.redhat.com/pages/viewpage.action?pageId=115488042"
        echo "3. Ask for help at Slack: #forum-dno-datarouter"
        save_status_data_router_failed "$CURRENT_DEPLOYMENT" true
        return
      else
        sleep $((wait_seconds_step * i))
      fi
    done

    # shellcheck disable=SC2317
    if [[ "$JOB_NAME" == *periodic-* ]]; then
      local max_attempts=30
      local wait_seconds=2
      for ((i = 1; i <= max_attempts; i++)); do
        # Get DataRouter request information.
        DATA_ROUTER_REQUEST_OUTPUT=$(oc exec -n "${droute_project}" "${droute_pod_name}" -- /bin/bash -c "
          ${temp_droute}/droute-linux-amd64 request get \
          --url ${DATA_ROUTER_URL} \
          --username ${DATA_ROUTER_USERNAME} \
          --password ${DATA_ROUTER_PASSWORD} \
          ${DATA_ROUTER_REQUEST_ID}")
        # Try to extract the ReportPortal launch URL from the request. This fails if it doesn't contain the launch URL.
        REPORTPORTAL_LAUNCH_URL=$(echo "$DATA_ROUTER_REQUEST_OUTPUT" | yq e '.targets[0].events[] | select(.component == "reportportal-connector") | .message | fromjson | .[0].launch_url' -)
        if [[ -n "$REPORTPORTAL_LAUNCH_URL" ]]; then
          save_status_url_reportportal $CURRENT_DEPLOYMENT $REPORTPORTAL_LAUNCH_URL
          reportportal_slack_alert $release_name $REPORTPORTAL_LAUNCH_URL
          return 0
        else
          echo "Attempt ${i} of ${max_attempts}: ReportPortal launch URL not ready yet."
          sleep "${wait_seconds}"
        fi
      done
    fi
    oc exec -n "${droute_project}" "${droute_pod_name}" -- /bin/bash -c "rm -rf ${temp_droute}/*"
    set -e
  ) # Close subshell
  oc config use-context "$original_context" # Restore original context
  if ! kubectl auth can-i get pods >/dev/null 2>&1; then
    echo "Failed to restore the context and authenticate with the cluster. Logging in again."
    oc_login
  fi
}

# Merge the base YAML value file with the differences file for Kubernetes
yq_merge_value_files() {
  local plugin_operation=$1 # Chose whether you want to merge or overwrite the plugins key (the second file will overwrite the first)
  local base_file=$2
  local diff_file=$3
  local step_1_file="/tmp/step-without-plugins.yaml"
  local step_2_file="/tmp/step-only-plugins.yaml"
  local final_file=$4
  if [ "$plugin_operation" = "merge" ]; then
    # Step 1: Merge files, excluding the .global.dynamic.plugins key
    # Values from `diff_file` override those in `base_file`
    yq eval-all '
      select(fileIndex == 0) * select(fileIndex == 1) |
      del(.global.dynamic.plugins)
    ' "${base_file}" "${diff_file}" > "${step_1_file}"
    # Step 2: Merge files, combining the .global.dynamic.plugins key
    # Values from `diff_file` take precedence; plugins are merged and deduplicated by the .package field
    yq eval-all '
      select(fileIndex == 0) *+ select(fileIndex == 1) |
      .global.dynamic.plugins |= (reverse | unique_by(.package) | reverse)
    ' "${base_file}" "${diff_file}" > "${step_2_file}"
    # Step 3: Combine results from the previous steps and remove null values
    # Values from `step_2_file` override those in `step_1_file`
    yq eval-all '
      select(fileIndex == 0) * select(fileIndex == 1) | del(.. | select(. == null))
    ' "${step_2_file}" "${step_1_file}" > "${final_file}"
  elif [ "$plugin_operation" = "overwrite" ]; then
    yq eval-all '
    select(fileIndex == 0) * select(fileIndex == 1)
  ' "${base_file}" "${diff_file}" > "${final_file}"
  else
    echo "Invalid operation with plugins key: $plugin_operation"
    exit 1
  fi
}

# Waits for a Kubernetes/OpenShift deployment to become ready within a specified timeout period
wait_for_deployment() {
    local namespace=$1
    local resource_name=$2
    local timeout_minutes=${3:-5}  # Default timeout: 5 minutes
    local check_interval=${4:-10}  # Default interval: 10 seconds

    # Validate required parameters
    if [[ -z "$namespace" || -z "$resource_name" ]]; then
        echo "Error: Missing required parameters"
        echo "Usage: wait_for_deployment <namespace> <resource-name> [timeout_minutes] [check_interval_seconds]"
        echo "Example: wait_for_deployment my-namespace my-deployment 5 10"
        return 1
    fi

    local max_attempts=$((timeout_minutes * 60 / check_interval))

    echo "Waiting for resource '$resource_name' in namespace '$namespace' (timeout: ${timeout_minutes}m)..."

    for ((i=1; i<=max_attempts; i++)); do
        # Get the first pod name matching the resource name
        local pod_name=$(oc get pods -n "$namespace" | grep "$resource_name" | awk '{print $1}' | head -n 1)

        if [[ -n "$pod_name" ]]; then
            # Check if pod's Ready condition is True
            local is_ready=$(oc get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
            # Verify pod is both Ready and Running
            if [[ "$is_ready" == "True" ]] && \
                oc get pod "$pod_name" -n "$namespace" | grep -q "Running"; then
                echo "Pod '$pod_name' is running and ready"
                return 0
            else
                echo "Pod '$pod_name' is not ready (Ready: $is_ready)"
            fi
        else
            echo "No pods found matching '$resource_name' in namespace '$namespace'"
        fi

        echo "Still waiting... (${i}/${max_attempts} checks)"
        sleep "$check_interval"
    done

    # Timeout occurred
    echo "Timeout waiting for resource to be ready. Please check:"
    echo "oc get pods -n $namespace | grep $resource_name"
    return 1
}

wait_for_svc(){
  local svc_name=$1
  local namespace=$2
  local timeout=${3:-300}

  timeout "${timeout}" bash -c "
    echo ${svc_name}
    while ! oc get svc $svc_name -n $namespace &> /dev/null; do
      echo \"Waiting for ${svc_name} service to be created...\"
      sleep 5
    done
    echo \"Service ${svc_name} is created.\"
    " || echo "Error: Timed out waiting for $svc_name service creation."
}

# Creates an OpenShift Operator subscription
install_subscription(){
  name=$1  # Name of the subscription
  namespace=$2 # Namespace to install the operator
  channel=$3 # Channel to subscribe to
  package=$4 # Package name of the operator
  source_name=$5 # Name of the source catalog
  source_namespace=$6 # Source namespace (typically openshift-marketplace or olm)
  # Apply the subscription manifest
  oc apply -f - << EOD
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $name
  namespace: $namespace
spec:
  channel: $channel
  installPlanApproval: Automatic
  name: $package
  source: $source_name
  sourceNamespace: $source_namespace
EOD
}

create_secret_dockerconfigjson(){
  namespace=$1
  secret_name=$2
  dockerconfigjson_value=$3
  echo "Creating dockerconfigjson secret $secret_name in namespace $namespace"
  kubectl apply -n "$namespace" -f - << EOD
apiVersion: v1
kind: Secret
metadata:
  name: $secret_name
data:
  .dockerconfigjson: $dockerconfigjson_value
type: kubernetes.io/dockerconfigjson
EOD
}
add_image_pull_secret_to_namespace_default_serviceaccount() {
  namespace=$1
  secret_name=$2
  echo "Adding image pull secret $secret_name to default service account"
  kubectl -n "${namespace}" patch serviceaccount default -p "{\"imagePullSecrets\": [{\"name\": \"${secret_name}\"}]}"
}
setup_image_pull_secret() {
  local namespace=$1
  local secret_name=$2
  local dockerconfigjson_value=$3
  echo "Creating $secret_name secret in $namespace namespace"
  create_secret_dockerconfigjson "$namespace" "$secret_name" "$dockerconfigjson_value"
  add_image_pull_secret_to_namespace_default_serviceaccount "$namespace" "$secret_name"
}

# Monitors the status of an operator in an OpenShift namespace.
# It checks the ClusterServiceVersion (CSV) for a specific operator to verify if its phase matches an expected value.
check_operator_status() {
  local timeout=${1:-300} # Timeout in seconds (default 300)
  local namespace=$2 # Namespace to check
  local operator_name=$3 # Operator name
  local expected_status=${4:-"Succeeded"} # Expected status phase (default Succeeded)

  echo "Checking the status of operator '${operator_name}' in namespace '${namespace}' with a timeout of ${timeout} seconds."
  echo "Expected status: ${expected_status}"

  timeout "${timeout}" bash -c "
    while true; do
      CURRENT_PHASE=\$(oc get csv -n '${namespace}' -o jsonpath='{.items[?(@.spec.displayName==\"${operator_name}\")].status.phase}')
      echo \"Operator '${operator_name}' current phase: \${CURRENT_PHASE}\"
      [[ \"\${CURRENT_PHASE}\" == \"${expected_status}\" ]] && echo \"Operator '${operator_name}' is now in '${expected_status}' phase.\" && break
      sleep 10
    done
  " || echo "Timed out after ${timeout} seconds. Operator '${operator_name}' did not reach '${expected_status}' phase."
}

# Installs the Crunchy Postgres Operator from Openshift Marketplace using predefined parameters
install_crunchy_postgres_ocp_operator(){
  install_subscription postgresql openshift-operators v5 postgresql community-operators openshift-marketplace
  check_operator_status 300 "openshift-operators" "Crunchy Postgres for Kubernetes" "Succeeded"
}

# Installs the Crunchy Postgres Operator from OperatorHub.io
install_crunchy_postgres_k8s_operator(){
  install_subscription postgresql openshift-operators v5 postgresql community-operators openshift-marketplace
  check_operator_status 300 "operators" "Crunchy Postgres for Kubernetes" "Succeeded"
}

uninstall_helmchart() {
  local project=$1
  local release=$2
  if helm list -n "${project}" | grep -q "${release}"; then
    echo "Chart already exists. Removing it before install."
    helm uninstall "${release}" -n "${project}"
  fi
}

configure_namespace() {
  local project=$1
  echo "Deleting and recreating namespace: $project"
  delete_namespace $project

  if ! oc create namespace "${project}"; then
      echo "Error: Failed to create namespace ${project}" >&2
      exit 1
  fi
  if ! oc config set-context --current --namespace="${project}"; then
      echo "Error: Failed to set context for namespace ${project}" >&2
      exit 1
  fi

  echo "Namespace ${project} is ready."
}

delete_namespace() {
  local project=$1
  if oc get namespace "$project" >/dev/null 2>&1; then
    echo "Namespace ${project} exists. Attempting to delete..."

    # Remove blocking finalizers
    # remove_finalizers_from_resources "$project"

    # Attempt to delete the namespace
    oc delete namespace "$project" --grace-period=0 --force || true

    # Check if namespace is still stuck in 'Terminating' and force removal if necessary
    if oc get namespace "$project" -o jsonpath='{.status.phase}' | grep -q 'Terminating'; then
      echo "Namespace ${project} is stuck in Terminating. Forcing deletion..."
      force_delete_namespace "$project"
    fi
  fi
}

configure_external_postgres_db() {
  local project=$1
  oc apply -f "${DIR}/resources/postgres-db/postgres.yaml" --namespace="${NAME_SPACE_POSTGRES_DB}"
  sleep 5
  oc get secret postgress-external-db-cluster-cert -n "${NAME_SPACE_POSTGRES_DB}" -o jsonpath='{.data.ca\.crt}' | base64 --decode > postgres-ca
  oc get secret postgress-external-db-cluster-cert -n "${NAME_SPACE_POSTGRES_DB}" -o jsonpath='{.data.tls\.crt}' | base64 --decode > postgres-tls-crt
  oc get secret postgress-external-db-cluster-cert -n "${NAME_SPACE_POSTGRES_DB}" -o jsonpath='{.data.tls\.key}' | base64 --decode > postgres-tsl-key

  oc create secret generic postgress-external-db-cluster-cert \
  --from-file=ca.crt=postgres-ca \
  --from-file=tls.crt=postgres-tls-crt \
  --from-file=tls.key=postgres-tsl-key \
  --dry-run=client -o yaml | oc apply -f - --namespace="${project}"

  POSTGRES_PASSWORD=$(oc get secret/postgress-external-db-pguser-janus-idp -n "${NAME_SPACE_POSTGRES_DB}" -o jsonpath={.data.password})
  sed_inplace "s|POSTGRES_PASSWORD:.*|POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}|g" "${DIR}/resources/postgres-db/postgres-cred.yaml"
  POSTGRES_HOST=$(echo -n "postgress-external-db-primary.$NAME_SPACE_POSTGRES_DB.svc.cluster.local" | base64 | tr -d '\n')
  sed_inplace "s|POSTGRES_HOST:.*|POSTGRES_HOST: ${POSTGRES_HOST}|g" "${DIR}/resources/postgres-db/postgres-cred.yaml"
  oc apply -f "${DIR}/resources/postgres-db/postgres-cred.yaml"  --namespace="${project}"
}

apply_yaml_files() {
  local dir=$1
  local project=$2
  local rhdh_base_url=$3
  echo "Applying YAML files to namespace ${project}"

  oc config set-context --current --namespace="${project}"

  local files=(
      "$dir/resources/service_account/service-account-rhdh.yaml"
      "$dir/resources/cluster_role_binding/cluster-role-binding-k8s.yaml"
      "$dir/resources/cluster_role/cluster-role-k8s.yaml"
      "$dir/resources/cluster_role/cluster-role-ocm.yaml"
    )

    for file in "${files[@]}"; do
      sed_inplace "s/namespace:.*/namespace: ${project}/g" "$file"
    done

    DH_TARGET_URL=$(echo -n "test-backstage-customization-provider-${project}.${K8S_CLUSTER_ROUTER_BASE}" | base64 -w 0)
    RHDH_BASE_URL=$(echo -n "$rhdh_base_url" | base64 | tr -d '\n')
    RHDH_BASE_URL_HTTP=$(echo -n "${rhdh_base_url/https/http}" | base64 | tr -d '\n')
    export DH_TARGET_URL RHDH_BASE_URL RHDH_BASE_URL_HTTP

    oc apply -f "$dir/resources/service_account/service-account-rhdh.yaml" --namespace="${project}"
    oc apply -f "$dir/auth/service-account-rhdh-secret.yaml" --namespace="${project}"

    oc apply -f "$dir/resources/cluster_role/cluster-role-k8s.yaml" --namespace="${project}"
    oc apply -f "$dir/resources/cluster_role_binding/cluster-role-binding-k8s.yaml" --namespace="${project}"
    oc apply -f "$dir/resources/cluster_role/cluster-role-ocm.yaml" --namespace="${project}"
    oc apply -f "$dir/resources/cluster_role_binding/cluster-role-binding-ocm.yaml" --namespace="${project}"

    OCM_CLUSTER_TOKEN=$(oc get secret rhdh-k8s-plugin-secret -n "${project}" -o=jsonpath='{.data.token}')
    export OCM_CLUSTER_TOKEN
    envsubst < "${DIR}/auth/secrets-rhdh-secrets.yaml" | oc apply --namespace="${project}" -f -

    # Select the configuration file based on the namespace or job
    config_file=$(select_config_map_file)
    # Apply the ConfigMap with the correct file
    create_app_config_map "$config_file" "$project"

    oc create configmap dynamic-plugins-config \
      --from-file="dynamic-plugins-config.yaml"="$dir/resources/config_map/dynamic-plugins-config.yaml" \
      --namespace="${project}" \
      --dry-run=client -o yaml | oc apply -f -

    if [[ "$JOB_NAME" == *operator* ]] && [[ "${project}" == *rbac* ]]; then
      oc create configmap rbac-policy \
        --from-file="rbac-policy.csv"="$dir/resources/config_map/rbac-policy.csv" \
        --from-file="conditional-policies.yaml"="/tmp/conditional-policies.yaml" \
        --namespace="$project" \
        --dry-run=client -o yaml | oc apply -f -
    else
      oc create configmap rbac-policy \
        --from-file="rbac-policy.csv"="$dir/resources/config_map/rbac-policy.csv" \
        --namespace="$project" \
        --dry-run=client -o yaml | oc apply -f -
    fi

    # configuration for testing global floating action button.
    oc create configmap dynamic-global-floating-action-button-config \
      --from-file="dynamic-global-floating-action-button-config.yaml"="$dir/resources/config_map/dynamic-global-floating-action-button-config.yaml" \
      --namespace="${project}" \
      --dry-run=client -o yaml | oc apply -f -

    # configuration for testing global header and header mount points.
    oc create configmap dynamic-global-header-config \
      --from-file="dynamic-global-header-config.yaml"="$dir/resources/config_map/dynamic-global-header-config.yaml" \
      --namespace="${project}" \
      --dry-run=client -o yaml | oc apply -f -

    # Create Pipeline run for tekton test case.
    oc apply -f "$dir/resources/pipeline-run/hello-world-pipeline.yaml"
    oc apply -f "$dir/resources/pipeline-run/hello-world-pipeline-run.yaml"

    # Create Deployment and Pipeline for Topology test.
    oc apply -f "$dir/resources/topology_test/topology-test.yaml"
    if [[ -z "${IS_OPENSHIFT}" || "$(to_lowercase "${IS_OPENSHIFT}")" == "false" ]]; then
      kubectl apply -f "$dir/resources/topology_test/topology-test-ingress.yaml"
    else
      oc apply -f "$dir/resources/topology_test/topology-test-route.yaml"
    fi

    # Create secret for sealight job to pull image from private quay repository.
    if [[ "$JOB_NAME" == *"sealight"* ]]; then kubectl create secret docker-registry quay-secret --docker-server=quay.io --docker-username=$RHDH_SEALIGHTS_BOT_USER --docker-password=$RHDH_SEALIGHTS_BOT_TOKEN --namespace="${project}"; fi
}

deploy_test_backstage_customization_provider() {
  local project=$1
  echo "Deploying test-backstage-customization-provider in namespace ${project}"

  # Check if the buildconfig already exists
  if ! oc get buildconfig test-backstage-customization-provider -n "${project}" >/dev/null 2>&1; then
    echo "Creating new app for test-backstage-customization-provider"
    oc new-app -S openshift/nodejs:18-minimal-ubi8
    oc new-app https://github.com/janus-qe/test-backstage-customization-provider --image-stream="openshift/nodejs:18-ubi8" --namespace="${project}"
  else
    echo "BuildConfig for test-backstage-customization-provider already exists in ${project}. Skipping new-app creation."
  fi

  echo "Exposing service for test-backstage-customization-provider"
  oc expose svc/test-backstage-customization-provider --namespace="${project}"
}

deploy_redis_cache() {
  local namespace=$1
  envsubst < "$DIR/resources/redis-cache/redis-secret.yaml" | oc apply --namespace="${namespace}" -f -
  oc apply -f "$DIR/resources/redis-cache/redis-deployment.yaml" --namespace="${namespace}"
}

create_app_config_map() {
  local config_file=$1
  local project=$2

  oc create configmap app-config-rhdh \
    --from-file="app-config-rhdh.yaml"="$config_file" \
    --namespace="$project" \
    --dry-run=client -o yaml | oc apply -f -
}

select_config_map_file() {
  if [[ "${project}" == *rbac* ]]; then
    echo "$dir/resources/config_map/app-config-rhdh-rbac.yaml"
  else
    echo "$dir/resources/config_map/app-config-rhdh.yaml"
  fi
}

create_dynamic_plugins_config() {
  local base_file=$1
  local final_file=$2
  echo "kind: ConfigMap
apiVersion: v1
metadata:
  name: dynamic-plugins
data:
  dynamic-plugins.yaml: |" > ${final_file}
  yq '.global.dynamic' ${base_file} | sed -e 's/^/    /' >> ${final_file}
}

create_conditional_policies_operator() {
  local destination_file=$1
  yq '.upstream.backstage.initContainers[0].command[2]' "${DIR}/value_files/values_showcase-rbac.yaml" | head -n -4 | tail -n +2 > $destination_file
  sed -i 's/\\\$/\$/g' $destination_file
}

prepare_operator_app_config() {
  local config_file=$1
  yq e -i '.permission.rbac.conditionalPoliciesFile = "./rbac/conditional-policies.yaml"' ${config_file}
}

run_tests() {
  local release_name=$1
  local project=$2
  cd "${DIR}/../../e2e-tests"
  local e2e_tests_dir
  e2e_tests_dir=$(pwd)

  yarn install --immutable > /tmp/yarn.install.log.txt 2>&1

  INSTALL_STATUS=$?
  if [ $INSTALL_STATUS -ne 0 ]; then
    echo "=== YARN INSTALL FAILED ==="
    cat /tmp/yarn.install.log.txt
    exit $INSTALL_STATUS
  else
    echo "Yarn install completed successfully."
  fi

  if [[ "$JOB_NAME" == *"sealight"* ]]; then node node_modules/sealights-playwright-plugin/importReplaceUtility.js playwright; fi

  yarn playwright install chromium

  Xvfb :99 &
  export DISPLAY=:99

  (
    set -e
    echo "Using PR container image: ${TAG_NAME}"
    yarn "$project"
  ) 2>&1 | tee "/tmp/${LOGFILE}"

  local RESULT=${PIPESTATUS[0]}

  pkill Xvfb

  mkdir -p "${ARTIFACT_DIR}/${project}/test-results"
  mkdir -p "${ARTIFACT_DIR}/${project}/attachments/screenshots"
  cp -a "${e2e_tests_dir}/test-results/"* "${ARTIFACT_DIR}/${project}/test-results"
  cp -a "${e2e_tests_dir}/${JUNIT_RESULTS}" "${ARTIFACT_DIR}/${project}/${JUNIT_RESULTS}"

  if [ -d "${e2e_tests_dir}/screenshots" ]; then
    cp -a "${e2e_tests_dir}/screenshots/"* "${ARTIFACT_DIR}/${project}/attachments/screenshots/"
  fi

  ansi2html <"/tmp/${LOGFILE}" >"/tmp/${LOGFILE}.html"
  cp -a "/tmp/${LOGFILE}.html" "${ARTIFACT_DIR}/${project}"
  cp -a "${e2e_tests_dir}/playwright-report/"* "${ARTIFACT_DIR}/${project}"

  droute_send "${release_name}" "${project}"

  echo "${project} RESULT: ${RESULT}"
  if [ "${RESULT}" -ne 0 ]; then
    save_overall_result 1
    save_status_test_failed $CURRENT_DEPLOYMENT true
  else
    save_status_test_failed $CURRENT_DEPLOYMENT false
  fi
  if [ -f "${e2e_tests_dir}/${JUNIT_RESULTS}" ]; then
    failed_tests=$(grep -oP 'failures="\K[0-9]+' "${e2e_tests_dir}/${JUNIT_RESULTS}" | head -n 1)
    echo "Number of failed tests: ${failed_tests}"
    save_status_number_of_test_failed $CURRENT_DEPLOYMENT "${failed_tests}"
  else
    echo "JUnit results file not found: ${e2e_tests_dir}/${JUNIT_RESULTS}"
    local failed_tests="some"
    echo "Number of failed tests unknown, saving as $failed_tests."
    save_status_number_of_test_failed $CURRENT_DEPLOYMENT "${failed_tests}"
  fi
}

check_backstage_running() {
  local release_name=$1
  local namespace=$2
  local url=$3
  local max_attempts=${4:-30}
  local wait_seconds=${5:-30}

  if [ -z "${url}" ]; then
    echo "Error: URL is not set. Please provide a valid URL."
    return 1
  fi

  echo "Checking if Backstage is up and running at ${url}"

  for ((i = 1; i <= max_attempts; i++)); do
    # Check HTTP status
    local http_status
    http_status=$(curl --insecure -I -s -o /dev/null -w "%{http_code}" "${url}")

    if [ "${http_status}" -eq 200 ]; then
      echo "✅ Backstage is up and running!"
      export BASE_URL="${url}"
      echo "BASE_URL: ${BASE_URL}"
      return 0
    else
      echo "Attempt ${i} of ${max_attempts}: Backstage not yet available (HTTP Status: ${http_status})"
      oc get pods -n "${namespace}"
      sleep "${wait_seconds}"
    fi
  done

  echo "❌ Failed to reach Backstage at ${url} after ${max_attempts} attempts."
  oc get events -n "${namespace}" --sort-by='.lastTimestamp' | tail -10
  mkdir -p "${ARTIFACT_DIR}/${namespace}"
  cp -a "/tmp/${LOGFILE}" "${ARTIFACT_DIR}/${namespace}/"
  save_all_pod_logs "${namespace}"
  return 1
}

install_olm() {
  if operator-sdk olm status > /dev/null 2>&1; then
    echo "OLM is already installed."
  else
    echo "OLM is not installed. Installing..."
    operator-sdk olm install
  fi
}

uninstall_olm() {
  if operator-sdk olm status > /dev/null 2>&1; then
    echo "OLM is installed. Uninstalling..."
    operator-sdk olm uninstall
  else
    echo "OLM is not installed. Nothing to uninstall."
  fi
}

# Installs the advanced-cluster-management OCP Operator
install_acm_ocp_operator(){
  oc apply -f "${DIR}/cluster/operators/acm/operator-group.yaml"
  install_subscription advanced-cluster-management open-cluster-management release-2.12 advanced-cluster-management redhat-operators openshift-marketplace
  wait_for_deployment "open-cluster-management" "multiclusterhub-operator"
  wait_for_svc multiclusterhub-operator-webhook open-cluster-management
  oc apply -f "${DIR}/cluster/operators/acm/multiclusterhub.yaml"
  # wait until multiclusterhub is Running.
  timeout 900 bash -c 'while true; do
    CURRENT_PHASE=$(oc get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath="{.status.phase}")
    echo "MulticlusterHub Current Status: $CURRENT_PHASE"
    [[ "$CURRENT_PHASE" == "Running" ]] && echo "MulticlusterHub is now in Running phase." && break
    sleep 10
  done' || echo "Timed out after 15 minutes"
}

# TODO
# Installs Open Cluster Management K8S Operator (alternative of advanced-cluster-management for K8S clusters)
# TODO: Verify K8s compatibility and enable OCM tests if compatible
install_ocm_k8s_operator(){
  install_subscription my-cluster-manager operators stable cluster-manager operatorhubio-catalog olm
  wait_for_deployment "operators" "cluster-manager"
  wait_for_svc multiclusterhub-operator-work-webhook open-cluster-management
  oc apply -f "${DIR}/cluster/operators/acm/multiclusterhub.yaml"
  # wait until multiclusterhub is Running.
  timeout 600 bash -c 'while true; do
    CURRENT_PHASE=$(oc get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath="{.status.phase}")
    echo "MulticlusterHub Current Status: $CURRENT_PHASE"
    [[ "$CURRENT_PHASE" == "Running" ]] && echo "MulticlusterHub is now in Running phase." && break
    sleep 10
  done' || echo "Timed out after 10 minutes"
}

# Installs the Red Hat OpenShift Pipelines operator if not already installed
install_pipelines_operator() {
  DISPLAY_NAME="Red Hat OpenShift Pipelines"
  # Check if operator is already installed
  if oc get csv -n "openshift-operators" | grep -q "${DISPLAY_NAME}"; then
    echo "Red Hat OpenShift Pipelines operator is already installed."
  else
    echo "Red Hat OpenShift Pipelines operator is not installed. Installing..."
    # Install the operator and wait for deployment
    install_subscription openshift-pipelines-operator openshift-operators latest openshift-pipelines-operator-rh redhat-operators openshift-marketplace
    wait_for_deployment "openshift-operators" "pipelines"
    timeout 300 bash -c '
    while ! oc get svc tekton-pipelines-webhook -n openshift-pipelines &> /dev/null; do
        echo "Waiting for tekton-pipelines-webhook service to be created..."
        sleep 5
    done
    echo "Service tekton-pipelines-webhook is created."
    ' || echo "Error: Timed out waiting for tekton-pipelines-webhook service creation."
  fi
}

# Installs the Tekton Pipelines if not already installed (alternative of OpenShift Pipelines for Kubernetes clusters)
install_tekton_pipelines() {
  DISPLAY_NAME="tekton-pipelines-webhook"
  if oc get pods -n "tekton-pipelines" | grep -q "${DISPLAY_NAME}"; then
    echo "Tekton Pipelines are already installed."
  else
    echo "Tekton Pipelines is not installed. Installing..."
    kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    wait_for_deployment "tekton-pipelines" "${DISPLAY_NAME}"
    timeout 300 bash -c '
    while ! kubectl get endpoints tekton-pipelines-webhook -n tekton-pipelines &> /dev/null; do
        echo "Waiting for tekton-pipelines-webhook endpoints to be ready..."
        sleep 5
    done
    echo "Endpoints for tekton-pipelines-webhook are ready."
    ' || echo "Error: Timed out waiting for tekton-pipelines-webhook endpoints."
  fi
}

delete_tekton_pipelines() {
    echo "Checking for Tekton Pipelines installation..."
    # Check if tekton-pipelines namespace exists
    if kubectl get namespace tekton-pipelines &> /dev/null; then
        echo "Found Tekton Pipelines installation. Attempting to delete..."
        # Delete the resources and ignore errors
        kubectl delete -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml --ignore-not-found=true 2>/dev/null || true
        # Wait for namespace deletion (with timeout)
        echo "Waiting for Tekton Pipelines namespace to be deleted..."
        timeout 30 bash -c '
        while kubectl get namespace tekton-pipelines &> /dev/null; do
            echo "Waiting for tekton-pipelines namespace deletion..."
            sleep 5
        done
        echo "Tekton Pipelines deleted successfully."
        ' || echo "Warning: Timed out waiting for namespace deletion, continuing..."
    else
        echo "Tekton Pipelines is not installed. Nothing to delete."
  fi
}

cluster_setup_ocp_helm() {
  install_pipelines_operator
  install_acm_ocp_operator
  install_crunchy_postgres_ocp_operator
  install_orchestrator_infra_chart
}

cluster_setup_ocp_operator() {
  install_pipelines_operator
  install_acm_ocp_operator
  install_crunchy_postgres_ocp_operator
  install_orchestrator_infra_chart
}

cluster_setup_k8s_operator() {
  install_olm
  install_tekton_pipelines
  # install_ocm_k8s_operator
  # install_crunchy_postgres_k8s_operator # Works with K8s but disabled in values file
}

cluster_setup_k8s_helm() {
  # install_olm
  install_tekton_pipelines
  # install_ocm_k8s_operator
  # install_crunchy_postgres_k8s_operator # Works with K8s but disabled in values file
}

install_orchestrator_infra_chart() {
  ORCH_INFRA_NS="orchestrator-infra"
  configure_namespace ${ORCH_INFRA_NS}

  echo "Deploying orchestrator-infra chart"
  cd "${DIR}"
  helm upgrade -i orch-infra -n "${ORCH_INFRA_NS}" \
    "oci://quay.io/rhdh/orchestrator-infra-chart" --version "${CHART_VERSION}" \
    --wait --timeout=5m \
    --set serverlessLogicOperator.subscription.spec.installPlanApproval=Automatic \
    --set serverlessOperator.subscription.spec.installPlanApproval=Automatic
}

# Helper function to get common helm set parameters
get_image_helm_set_params() {
  local params=""

  # Add image repository
  params+="--set upstream.backstage.image.repository=${QUAY_REPO} "

  # Add image tag
  params+="--set upstream.backstage.image.tag=${TAG_NAME} "

  # Add pull secrets if sealight job
  params+=$(if [[ "$JOB_NAME" == *"sealight"* ]]; then echo "--set upstream.backstage.image.pullSecrets[0]='quay-secret'"; fi)
  echo "${params}"
}

# Helper function to perform helm install/upgrade
perform_helm_install() {
  local release_name=$1
  local namespace=$2
  local value_file=$3
  
  helm upgrade -i "${release_name}" -n "${namespace}" \
    "${HELM_CHART_URL}" --version "${CHART_VERSION}" \
    -f "${DIR}/value_files/${value_file}" \
    --set global.clusterRouterBase="${K8S_CLUSTER_ROUTER_BASE}" \
    $(get_image_helm_set_params)
}

base_deployment() {
  configure_namespace ${NAME_SPACE}

  deploy_redis_cache "${NAME_SPACE}"

  cd "${DIR}"
  local rhdh_base_url="https://${RELEASE_NAME}-developer-hub-${NAME_SPACE}.${K8S_CLUSTER_ROUTER_BASE}"
  apply_yaml_files "${DIR}" "${NAME_SPACE}" "${rhdh_base_url}"
  echo "Deploying image from repository: ${QUAY_REPO}, TAG_NAME: ${TAG_NAME}, in NAME_SPACE: ${NAME_SPACE}"
  perform_helm_install "${RELEASE_NAME}" "${NAME_SPACE}" "${HELM_CHART_VALUE_FILE_NAME}"

  deploy_orchestrator_workflows "${NAME_SPACE}"
}

rbac_deployment() {
  configure_namespace "${NAME_SPACE_POSTGRES_DB}"
  configure_namespace "${NAME_SPACE_RBAC}"
  configure_external_postgres_db "${NAME_SPACE_RBAC}"

  # Initiate rbac instance deployment.
  local rbac_rhdh_base_url="https://${RELEASE_NAME_RBAC}-developer-hub-${NAME_SPACE_RBAC}.${K8S_CLUSTER_ROUTER_BASE}"
  apply_yaml_files "${DIR}" "${NAME_SPACE_RBAC}" "${rbac_rhdh_base_url}"
  echo "Deploying image from repository: ${QUAY_REPO}, TAG_NAME: ${TAG_NAME}, in NAME_SPACE: ${RELEASE_NAME_RBAC}"
  perform_helm_install "${RELEASE_NAME_RBAC}" "${NAME_SPACE_RBAC}" "${HELM_CHART_RBAC_VALUE_FILE_NAME}"
}

initiate_deployments() {
  cd "${DIR}"
  base_deployment
  rbac_deployment
}

# install base RHDH deployment before upgrade
initiate_upgrade_base_deployments() {
  local release_name=$1
  local namespace=$2
  local url=$3
  local max_attempts=${4:-30}    # Default to 30 if not set
  local wait_seconds=${5:-30}

  echo "Initiating base RHDH deployment before upgrade"

  CURRENT_DEPLOYMENT=$((CURRENT_DEPLOYMENT + 1))
  save_status_deployment_namespace $CURRENT_DEPLOYMENT "$namespace"

  configure_namespace "${namespace}"

  deploy_redis_cache "${namespace}"

  cd "${DIR}"

  apply_yaml_files "${DIR}" "${namespace}" "${url}"
  echo "Deploying image from base repository: ${QUAY_REPO_BASE}, TAG_NAME_BASE: ${TAG_NAME_BASE}, in NAME_SPACE: ${namespace}"

  # Get dynamic value file path based on previous release version
  local previous_release_value_file
  previous_release_value_file=$(get_previous_release_value_file "showcase")
  echo "Using dynamic value file: ${previous_release_value_file}"

  helm upgrade -i "${release_name}" -n "${namespace}" \
    "${HELM_CHART_URL}" --version "${CHART_VERSION_BASE}" \
    -f "${previous_release_value_file}" \
    --set global.clusterRouterBase="${K8S_CLUSTER_ROUTER_BASE}" \
    --set upstream.backstage.image.repository="${QUAY_REPO_BASE}" \
    --set upstream.backstage.image.tag="${TAG_NAME_BASE}"
}

initiate_upgrade_deployments() {
  local release_name=$1
  local namespace=$2
  local url=$3
  local max_attempts=${4:-30}    # Default to 30 if not set
  local wait_seconds=${5:-30}
  local wait_upgrade="10m"

  echo "Initiating upgrade deployment"
  cd "${DIR}"

  yq_merge_value_files "merge" "${DIR}/value_files/${HELM_CHART_VALUE_FILE_NAME}" "${DIR}/value_files/diff-values_showcase_upgrade.yaml" "/tmp/merged_value_file.yaml"
  echo "Deploying image from repository: ${QUAY_REPO}, TAG_NAME: ${TAG_NAME}, in NAME_SPACE: ${NAME_SPACE}"

  helm upgrade -i "${RELEASE_NAME}" -n "${NAME_SPACE}" \
  "${HELM_CHART_URL}" --version "${CHART_VERSION}" \
  -f "/tmp/merged_value_file.yaml" \
  --set global.clusterRouterBase="${K8S_CLUSTER_ROUTER_BASE}" \
  --set upstream.backstage.image.repository="${QUAY_REPO}" \
  --set upstream.backstage.image.tag="${TAG_NAME}" \
  --wait --timeout=${wait_upgrade}

  oc get pods -n "${namespace}"
  save_all_pod_logs $namespace
}

initiate_runtime_deployment() {
  local release_name=$1
  local namespace=$2
  configure_namespace "${namespace}"
  uninstall_helmchart "${namespace}" "${release_name}"
  sed_inplace "s|POSTGRES_USER:.*|POSTGRES_USER: $RDS_USER|g" "${DIR}/resources/postgres-db/postgres-cred.yaml"
  sed_inplace "s|POSTGRES_PASSWORD:.*|POSTGRES_PASSWORD: $(echo -n $RDS_PASSWORD | base64 -w 0)|g" "${DIR}/resources/postgres-db/postgres-cred.yaml"
  sed_inplace "s|POSTGRES_HOST:.*|POSTGRES_HOST: $(echo -n $RDS_1_HOST | base64 -w 0)|g" "${DIR}/resources/postgres-db/postgres-cred.yaml"
  oc apply -f "$DIR/resources/postgres-db/postgres-crt-rds.yaml" -n "${namespace}"
  oc apply -f "$DIR/resources/postgres-db/postgres-cred.yaml" -n "${namespace}"
  oc apply -f "$DIR/resources/postgres-db/dynamic-plugins-root-PVC.yaml" -n "${namespace}"
  # Create secret for sealight job to pull image from private quay repository.
  if [[ "$JOB_NAME" == *"sealight"* ]]; then kubectl create secret docker-registry quay-secret --docker-server=quay.io --docker-username=$RHDH_SEALIGHTS_BOT_USER --docker-password=$RHDH_SEALIGHTS_BOT_TOKEN --namespace="${namespace}"; fi

  helm upgrade -i "${release_name}" -n "${namespace}" \
    "${HELM_CHART_URL}" --version "${CHART_VERSION}" \
    -f "$DIR/resources/postgres-db/values-showcase-postgres.yaml" \
    --set global.clusterRouterBase="${K8S_CLUSTER_ROUTER_BASE}" \
    $(get_image_helm_set_params)
}

initiate_sanity_plugin_checks_deployment() {
  configure_namespace "${NAME_SPACE_SANITY_PLUGINS_CHECK}"
  uninstall_helmchart "${NAME_SPACE_SANITY_PLUGINS_CHECK}" "${RELEASE_NAME}"
  deploy_redis_cache "${NAME_SPACE_SANITY_PLUGINS_CHECK}"
  apply_yaml_files "${DIR}" "${NAME_SPACE_SANITY_PLUGINS_CHECK}" "${sanity_plugins_url}"
  yq_merge_value_files "overwrite" "${DIR}/value_files/${HELM_CHART_VALUE_FILE_NAME}" "${DIR}/value_files/${HELM_CHART_SANITY_PLUGINS_DIFF_VALUE_FILE_NAME}" "/tmp/${HELM_CHART_SANITY_PLUGINS_MERGED_VALUE_FILE_NAME}"
  mkdir -p "${ARTIFACT_DIR}/${NAME_SPACE_SANITY_PLUGINS_CHECK}"
  cp -a "/tmp/${HELM_CHART_SANITY_PLUGINS_MERGED_VALUE_FILE_NAME}" "${ARTIFACT_DIR}/${NAME_SPACE_SANITY_PLUGINS_CHECK}/" # Save the final value-file into the artifacts directory.
  helm upgrade -i "${RELEASE_NAME}" -n "${NAME_SPACE_SANITY_PLUGINS_CHECK}" \
    "${HELM_CHART_URL}" --version "${CHART_VERSION}" \
    -f "/tmp/${HELM_CHART_SANITY_PLUGINS_MERGED_VALUE_FILE_NAME}" \
    --set global.clusterRouterBase="${K8S_CLUSTER_ROUTER_BASE}" \
    $(get_image_helm_set_params)  \
    --set orchestrator.enabled=true
}

check_and_test() {
  local release_name=$1
  local namespace=$2
  local url=$3
  local max_attempts=${4:-30}    # Default to 30 if not set
  local wait_seconds=${5:-30}    # Default to 30 if not set

  CURRENT_DEPLOYMENT=$((CURRENT_DEPLOYMENT + 1))
  save_status_deployment_namespace $CURRENT_DEPLOYMENT "$namespace"

  if check_backstage_running "${release_name}" "${namespace}" "${url}" "${max_attempts}" "${wait_seconds}"; then
    save_status_failed_to_deploy $CURRENT_DEPLOYMENT false
    echo "Display pods for verification..."
    oc get pods -n "${namespace}"
    run_tests "${release_name}" "${namespace}"
  else
    echo "Backstage is not running. Exiting..."
    save_status_failed_to_deploy $CURRENT_DEPLOYMENT true
    save_status_test_failed $CURRENT_DEPLOYMENT true
    save_overall_result 1
  fi
  save_all_pod_logs $namespace
}

check_upgrade_and_test() {
  local deployment_name="$1"
  local release_name="$2"
  local namespace="$3"
  local url=$4
  local timeout=${5:-600} # Timeout in seconds (default: 600 seconds)

  if check_helm_upgrade "${deployment_name}" "${namespace}" "${timeout}"; then
    check_and_test "${release_name}" "${namespace}" "${url}"
  else
    echo "Helm upgrade encountered an issue or timed out. Exiting..."
    save_status_failed_to_deploy $CURRENT_DEPLOYMENT true
    save_status_test_failed $CURRENT_DEPLOYMENT true
    save_overall_result 1
  fi
}

check_helm_upgrade() {
  local deployment_name="$1"
  local namespace="$2"
  local timeout="$3"

  echo "Checking rollout status for deployment: ${deployment_name} in namespace: ${namespace}..."

  if oc rollout status "deployment/${deployment_name}" -n "${namespace}" --timeout="${timeout}s" -w; then
      echo "RHDH upgrade is complete."
      return 0
  else
      echo "RHDH upgrade encountered an issue or timed out."
      return 1
  fi
}

# Function to remove finalizers from specific resources in a namespace that are blocking deletion.
remove_finalizers_from_resources() {
  local project=$1
  echo "Removing finalizers from resources in namespace ${project} that are blocking deletion."

  # Remove finalizers from stuck PipelineRuns and TaskRuns
  for resource_type in "pipelineruns.tekton.dev" "taskruns.tekton.dev"; do
    for resource in $(oc get "$resource_type" -n "$project" -o name); do
      oc patch "$resource" -n "$project" --type='merge' -p '{"metadata":{"finalizers":[]}}' || true
      echo "Removed finalizers from $resource in $project."
    done
  done

  # Check and remove specific finalizers stuck on 'chains.tekton.dev' resources
  for chain_resource in $(oc get pipelineruns.tekton.dev,taskruns.tekton.dev -n "$project" -o name); do
    oc patch "$chain_resource" -n "$project" --type='json' -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true
    echo "Removed Tekton finalizers from $chain_resource in $project."
  done
}

# Function to forcibly delete a namespace stuck in 'Terminating' status
force_delete_namespace() {
  local project=$1
  echo "Forcefully deleting namespace ${project}."
  oc get namespace "$project" -o json | jq '.spec = {"finalizers":[]}' | oc replace --raw "/api/v1/namespaces/$project/finalize" -f -
}

oc_login() {
  oc login --token="${K8S_CLUSTER_TOKEN}" --server="${K8S_CLUSTER_URL}" --insecure-skip-tls-verify=true
  echo "OCP version: $(oc version)"
}

is_openshift() {
  oc get routes.route.openshift.io &> /dev/null || kubectl get routes.route.openshift.io &> /dev/null
}

detect_ocp_and_set_env_var() {
  echo "Detecting OCP or K8s and populating IS_OPENSHIFT variable..."
  if [[ "${IS_OPENSHIFT}" == "" ]]; then
    IS_OPENSHIFT=$(is_openshift && echo 'true' || echo 'false')
  fi
  echo IS_OPENSHIFT: "${IS_OPENSHIFT}"
}

# Helper function for cross-platform sed
sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "$@"
  else
    # Linux
    sed -i "$@"
  fi
}

# Helper function for case conversion
to_lowercase() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - using tr
    echo "$1" | tr '[:upper:]' '[:lower:]'
  else
    # Linux - using bash parameter expansion
    echo "${1,,}"
  fi
}

# Function to get the appropriate release version based on current branch
# Return the latest release version if current branch is not a release branch
# Return the previous release version if current branch is a release branch
get_previous_release_version() {
  local version=$1
  
  # Check if version parameter is provided
  if [[ -z "$version" ]]; then
    echo "Error: Version parameter is required" >&2
    exit 1
    save_overall_result 1
  fi
  
  # Validate version format (should be like "1.6")
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be in format X.Y (e.g., 1.6)" >&2
    exit 1
    save_overall_result 1
  fi
  
  # Extract major and minor version numbers
  local major_version=$(echo "$version" | cut -d'.' -f1)
  local minor_version=$(echo "$version" | cut -d'.' -f2)
  
  # Calculate previous minor version
  local previous_minor=$((minor_version - 1))
  
  # Check if previous minor version is valid (non-negative)
  if [[ $previous_minor -lt 0 ]]; then
    echo "Error: Cannot calculate previous version for $version" >&2
    exit 1
    save_overall_result 1
  fi
  
  # Return the previous version
  echo "${major_version}.${previous_minor}"
}

get_chart_version() {
  local chart_major_version=$1
  curl -sSX GET "https://quay.io/api/v1/repository/rhdh/chart/tag/?onlyActiveTags=true&filter_tag_name=like:${chart_major_version}-" -H "Content-Type: application/json" \
  | jq '.tags[0].name' | grep -oE '[0-9]+\.[0-9]+-[0-9]+-CI'
}

# Helper function to get dynamic value file path based on previous release version
get_previous_release_value_file() {
  local value_file_type=${1:-"showcase"}  # Default to showcase, can be "showcase-rbac" for RBAC

  # Get the previous release version
  local previous_release_version
  previous_release_version=$(get_previous_release_version "$CHART_MAJOR_VERSION")

  if [[ -z "$previous_release_version" ]]; then
    echo "Failed to determine previous release version." >&2
    save_overall_result 1
    exit 1
  fi

  echo "Using previous release version: ${previous_release_version}" >&2

  # Construct the GitHub URL for the value file
  local github_url="https://raw.githubusercontent.com/redhat-developer/rhdh/release-${previous_release_version}/.ibm/pipelines/value_files/values_${value_file_type}.yaml"

  # Create a temporary file path for the downloaded value file
  local temp_value_file="/tmp/values_${value_file_type}_${previous_release_version}.yaml"

  echo "Fetching value file from: ${github_url}" >&2

  # Download the value file from GitHub
  if curl -fsSL "${github_url}" -o "${temp_value_file}"; then
    echo "Successfully downloaded value file to: ${temp_value_file}" >&2
    echo "${temp_value_file}"
  else
    echo "Failed to download value file from GitHub." >&2
    save_overall_result 1
    exit 1
  fi
}

# Helper function to deploy workflows for orchestrator testing
deploy_orchestrator_workflows() {
  local namespace=$1

  local WORKFLOW_REPO="https://github.com/rhdh-orchestrator-test/serverless-workflows.git"
  local WORKFLOW_DIR="${DIR}/serverless-workflows"
  local WORKFLOW_MANIFESTS="${WORKFLOW_DIR}/workflows/experimentals/user-onboarding/manifests/"

  rm -rf "${WORKFLOW_DIR}"
  git clone "${WORKFLOW_REPO}" "${WORKFLOW_DIR}"

  if [[ "$namespace" == "${NAME_SPACE_RBAC}" ]]; then
    local pqsl_secret_name="postgres-cred"
    local pqsl_user_key="POSTGRES_USER"
    local pqsl_password_key="POSTGRES_PASSWORD"
    local pqsl_svc_name="postgress-external-db-primary"
    local patch_namespace="${NAME_SPACE_POSTGRES_DB}"
  else
    local pqsl_secret_name="rhdh-postgresql-svcbind-postgres"
    local pqsl_user_key="username"
    local pqsl_password_key="password"
    local pqsl_svc_name="rhdh-postgresql"
    local patch_namespace="$namespace"
  fi

  oc apply -f "${WORKFLOW_MANIFESTS}"

  helm repo add orchestrator-workflows https://rhdhorchestrator.io/serverless-workflows
  helm install greeting orchestrator-workflows/greeting -n "$namespace"

  until [[ $(oc get sf -n "$namespace" --no-headers 2>/dev/null | wc -l) -eq 2 ]]; do
    echo "No sf resources found. Retrying in 5 seconds..."
    sleep 5
  done

  for workflow in greeting user-onboarding; do
    oc -n "$namespace" patch sonataflow "$workflow" --type merge -p "{\"spec\": { \"persistence\": { \"postgresql\": { \"secretRef\": {\"name\": \"$pqsl_secret_name\",\"userKey\": \"$pqsl_user_key\",\"passwordKey\": \"$pqsl_password_key\"},\"serviceRef\": {\"name\": \"$pqsl_svc_name\",\"namespace\": \"$patch_namespace\"}}}}}"
  done
}