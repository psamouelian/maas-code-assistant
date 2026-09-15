#!/bin/bash

set -ex

cd "$(dirname "$(realpath "$0")")"

oc apply -f gatewayclass.yaml
oc apply -f gateway.yaml
{{- with $db := .Values.postgresCluster }}
{{- if $db.create }}

oc rollout status -n cloudnative-pg deployment/cnpg-controller-manager
sleep 5
oc apply -f cluster.yaml
while ! [ "$(oc get cluster -n {{ $db.namespace }} {{ $db.name }} -o jsonpath='{.status.readyInstances}')" -eq "{{ $db.instances | default 1 }}" ]; do
  sleep 5
done
uri=$(oc get secret -n {{ $db.namespace }} {{ $db.name }}-app -ojsonpath='{.data.uri}' | base64 -d)
oc create secret generic maas-db-config -n redhat-ods-applications --from-literal=DB_CONNECTION_URL="$uri" --dry-run=client -oyaml | oc apply -f-
{{- end }}
{{- end }}

# ----------------------------------------------------------------------------
# DSCInitialization and DataScienceCluster are cluster singletons. On a cluster
# that already runs Red Hat OpenShift AI, one of each already exists — possibly
# under a different name. Blindly applying our own `default-dsci`/`default-dsc`
# would either (a) be rejected by the operator as a duplicate singleton, making
# `oc apply` fail forever in the loop below (the "hard stop"), or (b) overwrite
# the customer's component configuration. Instead we coexist: reuse whatever is
# already there and only enable the components this quickstart requires, leaving
# every other component the customer configured untouched.
# ----------------------------------------------------------------------------

existing_dsci=$(oc get dscinitialization -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$existing_dsci" ]; then
  echo "Reusing existing DSCInitialization '$existing_dsci' (leaving it unmodified)."
else
  oc apply -f dscinitialization.yaml
fi

existing_dsc=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$existing_dsc" ]; then
  echo "Existing DataScienceCluster '$existing_dsc' found — enabling required components without disturbing others."
  # Merge patch: only the components this quickstart needs are set to Managed.
  # Merge semantics preserve any other components the customer already enabled.
  oc patch datasciencecluster "$existing_dsc" --type=merge \
    -p '{"spec":{"components":{{ .Values.dataScienceCluster.components | toJson }}}}'
else
  while ! oc apply -f datasciencecluster.yaml; do
    sleep 5
  done
fi
