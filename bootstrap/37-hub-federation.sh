#!/usr/bin/env bash
# OSAC single-login federation (OSAC-6437 Phase 1; OSAC-8173): what the Phase 0 spike did by hand
# on sno-01, as a rerunnable step. The hub's OpenShift OAuth gains an OIDC identity provider that
# federates to the Keycloak realm osac (apps/keycloak/manifests/realm-osac.yaml, Argo CD app
# keycloak imports it once this script creates its Secret), so the OSAC UI proxy can exchange an
# OSAC session for a hub token. Also: a provider-admin test user in the realm, the ClusterRoleBinding
# that makes the federated user a provider admin, and (when OSAC_PROXY_REDIRECTS is set) the
# OAuthClient the OSAC UI proxy's grid package uses. Run after make hub; safe to rerun.
source "$(dirname "$0")/lib.sh"
ns=$KEYCLOAK_NS realm=osac idp=osac client=openshift-oauth-osac user=provider-admin
kc $HOST get secret ai-grid-tenant-idps -n $ns >/dev/null 2>&1 || die "run bootstrap/35-keycloak.sh first"
kchost=$(kc $HOST get route maas-keycloak -n $ns -o jsonpath='{.spec.host}')
oauthhost=$(kc $HOST get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}')
[[ -n $oauthhost ]] || die "route oauth-openshift missing: not an OpenShift hub?"
callback="https://$oauthhost/oauth2callback/$idp"
issuer="https://$kchost/realms/$realm"
# Secret ai-grid-hub-federation holds the realm import's placeholders (callback URL + client
# secret); the client secret is kept across reruns, like the console's OAuthClient secret.
cs=$(kc $HOST get secret ai-grid-hub-federation -n $ns -o jsonpath='{.data.hub-oauth-client-secret}' 2>/dev/null | base64 -d || true)
cs=${cs:-$(openssl rand -hex 32)}
CS=$cs jq -n --arg cb "$callback" --arg ns "$ns" '{apiVersion:"v1", kind:"Secret", metadata:{name:"ai-grid-hub-federation", namespace:$ns},
  stringData:{"hub-oauth-callback":$cb, "hub-oauth-client-secret":env.CS}}' | kc $HOST apply -f - >/dev/null
# The realm import runs once per realm; wait for it (Argo CD syncs realm-osac.yaml once the
# Secret above exists).
wait_created $HOST keycloakrealmimport/$realm $ns 900
kc $HOST wait keycloakrealmimport/$realm -n $ns --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True --timeout=15m
for _ in $(seq 1 60); do curl -fsS -o /dev/null "$issuer/.well-known/openid-configuration" && break; sleep 10; done
curl -fsS -o /dev/null "$issuer/.well-known/openid-configuration" || die "realm $realm discovery not answering"
# A provider-admin test user in the realm (the OSAC stand-in user; production users come from the
# OSAC Keycloak). Password in Secret ai-grid-test-users, as bootstrap/35-keycloak.sh keeps them.
au=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.username}' | base64 -d)
ap=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.password}' | base64 -d)
# Secrets reach curl through a pipe or a file descriptor, never argv (where ps shows them).
tok=$(printf %s "$ap" | curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$au" \
  --data-urlencode password@- "https://$kchost/realms/master/protocol/openid-connect/token" | jq -r .access_token); unset ap
[[ -n $tok && $tok != null ]] || die "Keycloak admin login failed"
api() { curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$tok") -H 'Content-Type: application/json' "$@"; }
base="https://$kchost/admin/realms/$realm"
kc $HOST get secret ai-grid-test-users -n $ns >/dev/null 2>&1 || kc $HOST create secret generic ai-grid-test-users -n $ns >/dev/null
uid=$(api "$base/users?username=$user&exact=true" | jq -r '.[0].id // empty')
pw=$(kc $HOST get secret ai-grid-test-users -n $ns -o jsonpath='{.data.osac-provider-admin}' 2>/dev/null | base64 -d || true)
pw=${pw:-$(openssl rand -base64 18)}
if [[ -z $uid ]]; then
  PW=$pw jq -n --arg u "$user" '{username:$u, enabled:true, emailVerified:true, firstName:"Provider", lastName:"Admin",
    email:"provider-admin@osac.invalid", credentials:[{type:"password", value:env.PW, temporary:false}]}' \
    | api -X POST "$base/users" --data-binary @- >/dev/null
  uid=$(api "$base/users?username=$user&exact=true" | jq -re '.[0].id')
else
  PW=$pw jq -n '{type:"password", value:env.PW, temporary:false}' | api -X PUT "$base/users/$uid/reset-password" -d @- >/dev/null
fi
[[ -n $uid && $uid != null ]] || die "user $user in realm $realm not set up"
B64=$(printf '%s' "$pw" | base64 | tr -d '\n') jq -n '{data: {("osac-provider-admin"): env.B64}}' \
  | kc $HOST patch secret ai-grid-test-users -n $ns --type merge --patch-file /dev/stdin >/dev/null
unset tok pw
# The OAuth identity provider: the client secret (an OpenShift Secret in openshift-config) and the
# ingress router CA (Phase 0 finding: without openID.ca the hub reports TLS unknown-authority).
CS2=$cs jq -n '{apiVersion:"v1", kind:"Secret", metadata:{name:"osac-federation", namespace:"openshift-config"},
  type:"Opaque", stringData:{clientSecret:env.CS2}}' | kc $HOST apply -f - >/dev/null
unset cs CS2
# Copy the ingress router CA (Phase 0 finding: without openID.ca the hub reports
# TLS unknown-authority). The data is compared first so a rotated router-ca
# refreshes the copy on rerun instead of being skipped.
ca_new=$(kc $HOST get configmap router-ca -n openshift-config-managed -o json | jq -c '.data')
ca_old=$(kc $HOST get configmap osac-federation-ca -n openshift-config -o json 2>/dev/null | jq -c '.data')
if [[ $ca_new != "$ca_old" ]]; then
  kc $HOST get configmap router-ca -n openshift-config-managed -o json \
    | jq '{apiVersion:"v1", kind:"ConfigMap", metadata:{name:"osac-federation-ca", namespace:"openshift-config"}, data:.data}' \
    | kc $HOST apply -f - >/dev/null
fi
unset ca_new ca_old
# Patch OAuth/cluster additively: keep every existing identity provider, replace only an earlier
# osac entry with this one. The array is sent whole (merge patch replaces it), so it is read live.
idp_json=$(jq -nc --arg n "$idp" --arg iss "$issuer" --arg cid "$client" \
  '{name:$n, mappingMethod:"claim", type:"OpenID",
    openID:{issuer:$iss, clientID:$cid, clientSecret:{name:"osac-federation"}, ca:{name:"osac-federation-ca"},
      claims:{preferredUsername:["preferred_username"], name:["name"], email:["email"]}}}')
new_idps=$(kc $HOST get oauth cluster -o json \
  | jq --argjson idp "$idp_json" '[.spec.identityProviders[]? | select(.name != $idp.name)] + [$idp]')
jq -n --argjson idps "$new_idps" '{spec:{identityProviders:$idps}}' | kc $HOST patch oauth cluster --type merge --patch-file /dev/stdin >/dev/null
# The authentication operator rolls the oauth-openshift pods; wait until it has
# observed the patch (Progressing=True at least once) and settled again. The
# operator has not seen the patch right after it is applied, so its pre-patch
# Progressing=False/Available=True would break the loop immediately; and a
# no-op rerun that never reports Progressing is legitimate, so it is warned
# about, not fatal.
seen_progressing=false
for _ in $(seq 1 90); do
  prog=$(kc $HOST get clusteroperator authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')
  [[ $prog == True ]] && seen_progressing=true
  if [[ $seen_progressing == true && $prog == False \
    && $(kc $HOST get clusteroperator authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}') == True ]]; then
    break
  fi
  sleep 10
done
[[ $seen_progressing == true ]] || log "warning: authentication never reported Progressing after the IdP patch (no-op rerun?)"
[[ $(kc $HOST get clusteroperator authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}') == True ]] \
  || die "clusteroperator authentication not Available after adding IdP $idp"
# The federated user (preferred_username claim) gets provider-admin: the ClusterRole the console
# chart creates, bound to the OpenShift user the first login will create.
kc $HOST get clusterrole ai-grid-provider-admin >/dev/null 2>&1 \
  || die "ClusterRole ai-grid-provider-admin missing: deploy the provider console first (make console)"
jq -n --arg u "$user" '{apiVersion:"rbac.authorization.k8s.io/v1", kind:"ClusterRoleBinding",
  metadata:{name:"ai-grid-osac-provider-admin"}, roleRef:{apiGroup:"rbac.authorization.k8s.io", kind:"ClusterRole",
  name:"ai-grid-provider-admin"}, subjects:[{apiGroup:"rbac.authorization.k8s.io", kind:"User", name:$u}]}' \
  | kc $HOST apply -f - >/dev/null
# The OSAC UI proxy's OAuthClient (its grid package exchanges codes for hub tokens, PKCE S256).
# OSAC_PROXY_REDIRECTS is a space-separated list of exact callback URIs
# (https://<osac-ui-host>/api/grids/<grid-id>/callback); without it the client is not created.
if [[ -n ${OSAC_PROXY_REDIRECTS:-} ]]; then
  ps=$(kc $HOST get secret ai-grid-proxy-oauth -n $ns -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d || true)
  ps=${ps:-$(openssl rand -hex 32)}
  PS=$ps jq -n --argjson r "$(printf '%s\n' $OSAC_PROXY_REDIRECTS | jq -R . | jq -s .)" \
    '{apiVersion:"oauth.openshift.io/v1", kind:"OAuthClient", metadata:{name:"ai-grid-proxy"},
    grantMethod:"auto", redirectURIs:$r, secret:env.PS}' | kc $HOST apply -f - >/dev/null
  PS=$ps jq -n --arg ns "$ns" '{apiVersion:"v1", kind:"Secret", metadata:{name:"ai-grid-proxy-oauth", namespace:$ns},
    type:"Opaque", stringData:{clientID:"ai-grid-proxy", clientSecret:env.PS}}' | kc $HOST apply -f - >/dev/null
  unset ps PS
fi
# Record what the OSAC deployment and verify/12-hub-federation.sh need.
kc $HOST patch configmap ai-grid-hub-info -n ai-grid-policies --type merge -p "{\"data\":{
  \"osacIdPName\":\"$idp\",\"osacIssuer\":\"$issuer\",\"osacRealmClient\":\"$client\"}}" >/dev/null
log "hub federation: IdP $idp -> $issuer; user $user (password in Secret ai-grid-test-users/$user); \
sign in at the console with the $idp provider to create the OpenShift user"
