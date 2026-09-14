#!/bin/bash
# ============================================================================
# Additively register the rhbk OpenID identity provider on the cluster OAuth.
#
# IMPORTANT: This must NOT replace the cluster's identityProviders array.
# A `oc patch --type=merge` with a full identityProviders list REPLACES the
# entire array (JSON merge patch semantics), silently wiping any pre-existing
# identity providers (htpasswd, LDAP, other OIDC) on a customer cluster and
# potentially locking every existing admin out. Instead we read the live list,
# drop any stale 'rhbk' entry, append ours, and patch the merged list back.
# ============================================================================

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to safely merge identity providers but was not found in the tools image." >&2
  exit 1
fi

# Desired rhbk identity provider. Rendered by Helm (this file is tpl-processed
# by the patch-oauth Job template before being placed in the ConfigMap).
RHBK_IDP=$(cat <<EOF
{
  "name": "rhbk",
  "type": "OpenID",
  "mappingMethod": "claim",
  "openID": {
    {{- if .Values.ingressCA }}
    "ca": { "name": "router-ca" },
    {{- end }}
    "claims": {
      "email": ["email"],
      "name": ["name"],
      "preferredUsername": ["preferred_username", "email", "name"],
      "groups": ["groups"]
    },
    "clientID": "{{ .Values.realm.openshiftClientId }}",
    "clientSecret": { "name": "openid-client-secret" },
    "extraScopes": [],
    "issuer": "https://{{ .Values.name }}.{{ .Values.global.wildcardDomain }}/realms/{{ .Values.realm.name }}"
  }
}
EOF
)

# Validate the rendered provider is well-formed JSON before touching the cluster.
if ! echo "$RHBK_IDP" | jq empty >/dev/null 2>&1; then
  echo "ERROR: rendered rhbk identity provider is not valid JSON; refusing to patch OAuth." >&2
  exit 1
fi

current=$(oc get oauth cluster -o json)

# Existing providers with any prior 'rhbk' removed (idempotent re-runs).
existing=$(echo "$current" | jq '[(.spec.identityProviders // [])[] | select(.name != "rhbk")]')

merged=$(jq -n --argjson e "$existing" --argjson n "$RHBK_IDP" '$e + [$n]')

patch=$(jq -n --argjson m "$merged" '{spec:{identityProviders:$m}}')

echo "Registering rhbk identity provider (preserving $(echo "$existing" | jq 'length') existing provider(s))..."
oc patch oauth cluster --type=merge -p "$patch"
