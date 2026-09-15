#!/bin/bash
# ============================================================================
# MaaS Code Assistant — Prerequisites Check
# ============================================================================

check_prerequisites() {
  local missing=()

  # ---- OpenShift version ----
  log_status "running" "validating" "Checking OpenShift version..."
  local ocp_version
  ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "")
  if [[ -z "$ocp_version" ]]; then
    missing+=("{\"name\":\"OpenShift Version\",\"reason\":\"Unable to determine OpenShift version. Are you logged in with cluster-admin?\"}")
  else
    local ocp_major ocp_minor
    ocp_major=$(echo "$ocp_version" | cut -d. -f1)
    ocp_minor=$(echo "$ocp_version" | cut -d. -f2)
    if [[ "$ocp_major" -lt 4 ]] || { [[ "$ocp_major" -eq 4 ]] && [[ "$ocp_minor" -lt 20 ]]; }; then
      missing+=("{\"name\":\"OpenShift Version\",\"reason\":\"Requires OpenShift 4.20+, found ${ocp_version}\"}")
    else
      log_status "running" "validating" "OpenShift version ${ocp_version} OK"
    fi
  fi

  # ---- Cluster-admin access ----
  log_status "running" "validating" "Checking cluster-admin access..."
  if ! oc auth can-i create namespaces --all-namespaces 2>/dev/null | grep -q "yes"; then
    missing+=("{\"name\":\"Cluster Admin\",\"reason\":\"Current user does not have cluster-admin privileges\"}")
  fi

  # ---- Default StorageClass ----
  log_status "running" "validating" "Checking for default StorageClass..."
  local default_sc
  default_sc=$(oc get storageclass -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' 2>/dev/null || echo "")
  if [[ -z "$default_sc" ]]; then
    missing+=("{\"name\":\"Default StorageClass\",\"reason\":\"No default StorageClass found. A default StorageClass with ReadWriteOnce access is required.\"}")
  else
    log_status "running" "validating" "Default StorageClass '${default_sc}' found"
  fi

  # ---- NVIDIA GPU Operator ----
  log_status "running" "validating" "Checking NVIDIA GPU Operator..."
  local gpu_csv
  gpu_csv=$(oc get csv -A 2>/dev/null | grep -i "gpu-operator" | grep -i "succeeded" || echo "")
  if [[ -z "$gpu_csv" ]]; then
    missing+=("{\"name\":\"NVIDIA GPU Operator\",\"reason\":\"NVIDIA GPU Operator is not installed or not in Succeeded phase. Install it and configure a ClusterPolicy before deploying this quickstart.\"}")
  else
    log_status "running" "validating" "NVIDIA GPU Operator found and Succeeded"
  fi

  # ---- GPU nodes with sufficient VRAM ----
  log_status "running" "validating" "Checking for GPU nodes..."
  local gpu_node_count
  gpu_node_count=$(oc get nodes -o json 2>/dev/null | \
    jq '[.items[] | select(.status.capacity["nvidia.com/gpu"] != null and (.status.capacity["nvidia.com/gpu"] | tonumber) > 0)] | length' 2>/dev/null || echo "0")
  if [[ "$gpu_node_count" -eq 0 ]]; then
    missing+=("{\"name\":\"GPU Nodes\",\"reason\":\"No nodes with nvidia.com/gpu capacity found. At least one node with an NVIDIA GPU (48GB+ VRAM) is required.\"}")
  else
    log_status "running" "validating" "Found ${gpu_node_count} GPU node(s)"
  fi

  # ---- Pre-existing operators: coexist + version compatibility ----
  # The installer never takes ownership of operators already on the cluster. If
  # an operator it needs is already installed, it COEXISTS with it — it does not
  # adopt, reconfigure, or (on uninstall) remove it, so other applications that
  # depend on that operator are unaffected. If an operator is absent, the
  # installer installs it. Here we report which operators are already present and
  # fail the check if a pre-existing one is OLDER than this quickstart requires
  # (since coexist means we will not upgrade it).
  log_status "running" "validating" "Checking for pre-existing operators (coexist mode)..."
  # Publish the detected set as globals so deploy_quickstart() can reuse it
  # WITHOUT re-querying the cluster. INSTALL always runs this function before
  # deploy_quickstart() (see entrypoint.sh), so these are populated even when the
  # user skips the standalone CHECK_PRE_REQS action. COEXIST_DETECTED lets the
  # consumer prove detection actually ran rather than defaulting to "none".
  # (Deliberately NOT declared 'local' — they must outlive this function.)
  COEXISTING_OPERATORS=()
  COEXIST_DETECTED=true

  local subs_json csvs_json
  subs_json=$(oc get subscriptions -A -o json 2>/dev/null || echo '{"items":[]}')
  csvs_json=$(oc get csv -A -o json 2>/dev/null || echo '{"items":[]}')

  # "subscription-name|minimum-version|display-name" — empty minimum = any version OK.
  local operator_specs=(
    "rhods-operator|3.4.0|Red Hat OpenShift AI"
    "rhcl-operator|1.3.4|Red Hat Connectivity Link"
    "cluster-observability-operator|1.4.0|Cluster Observability Operator"
    "rhbk-operator||Red Hat Build of Keycloak"
    "devspaces||OpenShift Dev Spaces"
    "openshift-cert-manager-operator||cert-manager Operator"
    "leader-worker-set||Leader Worker Set Operator"
    "cloudnative-pg||CloudNativePG"
    "opentelemetry-product||OpenTelemetry Product"
  )

  local spec op_name min_ver disp installed_csv installed_ver oldest
  for spec in "${operator_specs[@]}"; do
    IFS='|' read -r op_name min_ver disp <<< "$spec"

    installed_csv=$(echo "$subs_json" | \
      jq -r --arg n "$op_name" '[.items[] | select(.spec.name==$n) | .status.installedCSV] | map(select(. != null and . != "")) | .[0] // ""' 2>/dev/null || echo "")
    if [[ -z "$installed_csv" ]]; then
      continue  # not installed — the quickstart will install it
    fi

    # Installed — record it so the install step disables it (coexist). Recording
    # here (rather than re-querying later) is what keeps the two steps in sync.
    COEXISTING_OPERATORS+=("$op_name")

    installed_ver=$(echo "$csvs_json" | \
      jq -r --arg c "$installed_csv" '[.items[] | select(.metadata.name==$c) | .spec.version] | .[0] // ""' 2>/dev/null || echo "")

    if [[ -n "$min_ver" && -n "$installed_ver" ]]; then
      oldest=$(printf '%s\n%s\n' "$min_ver" "$installed_ver" | sort -V | head -1)
      if [[ "$oldest" != "$min_ver" ]]; then
        missing+=("{\"name\":\"${disp}\",\"reason\":\"Pre-existing ${disp} ${installed_ver} is older than the required ${min_ver}. The installer coexists with (does not upgrade) operators already on the cluster. Upgrade it to ${min_ver}+ before installing, or remove it so the installer can install the required version.\"}")
        continue
      fi
    fi

    log_status "running" "validating" "Pre-existing ${disp} detected (${installed_ver:-version unknown}) — the installer will coexist with it and will NOT remove it on uninstall."
  done

  # ---- Cluster-wide authentication impact awareness ----
  # Installation registers a cluster-wide OpenID identity provider and grants the
  # Keycloak "admin" user cluster-admin. If the only admin path becomes this
  # quickstart's SSO admin, an interrupted install or a later uninstall can lock
  # everyone out. Surface this and check for a break-glass credential.
  log_status "running" "validating" "NOTE: Installation modifies CLUSTER-WIDE authentication (adds an OpenID identity provider and grants the Keycloak 'admin' user cluster-admin). The OAuth patch is additive — existing identity providers (e.g. Google, htpasswd, LDAP) are preserved. Retain an independent admin credential (kubeadmin password, admin kubeconfig, or a pre-existing identity provider) before installing."
  if ! oc get secret kubeadmin -n kube-system >/dev/null 2>&1; then
    local other_idps
    other_idps=$(oc get oauth cluster -o json 2>/dev/null | \
      jq -r '[(.spec.identityProviders // [])[] | select(.name != "rhbk") | .name] | join(", ")' 2>/dev/null || echo "")
    if [[ -n "$other_idps" ]]; then
      log_status "running" "validating" "NOTE: kubeadmin is absent, but an independent identity provider is configured (${other_idps}) and this install preserves it. Verify you can log in as cluster-admin through it before installing."
    else
      log_status "running" "validating" "WARNING: kubeadmin secret is absent and no independent identity provider is configured. If you do not hold an independent admin kubeconfig, an interrupted install could permanently lock you out. Installation will require ACKNOWLEDGE_NO_BREAKGLASS=true to proceed."
    fi
  fi

  # ---- Evaluate results ----
  if [[ ${#missing[@]} -gt 0 ]]; then
    local missing_json
    missing_json=$(printf '%s,' "${missing[@]}")
    missing_json="[${missing_json%,}]"
    log_prerequisites_failed "$missing_json"
    return 2
  fi

  return 0
}
