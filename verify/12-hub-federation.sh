#!/usr/bin/env bash
# OSAC single-login federation (Task: OSAC-6437 Phase 1; OSAC-8173): the hub's OAuth federates to
# the Keycloak realm osac, and the federated user is a provider admin. Run bootstrap/37-hub-federation.sh
# first. The SSAR check impersonates the user, so it passes before anyone has signed in; the token
# chain itself (silent login through the OSAC UI proxy) is verified against a live deployment with
# the OSAC-8173 verification kit, not here.
source "$(dirname "$0")/lib.sh"
ns=$KEYCLOAK_NS idp=osac realm=osac user=provider-admin
info=ai-grid-hub-info
issuer=$(kc $HOST get configmap $info -n ai-grid-policies -o jsonpath='{.data.osacIssuer}')
uat "federation info recorded" "run bootstrap/37-hub-federation.sh first" bash -c "[[ -n $issuer ]]"
uat "realm import done" "keycloakrealmimport/$realm not Done: Argo CD app keycloak out of sync, or Secret ai-grid-hub-federation missing (bootstrap/37-hub-federation.sh)" \
  bash -c "[[ \$(kc $HOST get keycloakrealmimport/$realm -n $ns -o jsonpath='{.status.conditions[?(@.type==\"Done\")].status}') == True ]]"
uat "IdP on the hub" "IdP $idp not in oauth cluster (bootstrap/37-hub-federation.sh)" \
  bash -c "kc $HOST get oauth cluster -o json | jq -e '.spec.identityProviders[] | select(.name == \"$idp\" and .type == \"OpenID\")' >/dev/null"
# The same-Keycloak-host condition the silent flow depends on: the IdP's issuer must be the
# Keycloak this hub runs (realm $realm under route maas-keycloak), or the browser's OSAC session
# cookies will not apply and single-login degrades to a login form.
uat "issuer is the hub's Keycloak" "IdP issuer ($idp) is not realm $realm under the hub's maas-keycloak route: the silent SSO precondition (same Keycloak host and realm) fails" \
  bash -c "kc $HOST get oauth cluster -o json | jq -e --arg i \"\$issuer\" '.spec.identityProviders[] | select(.name == \"$idp\") | .openID.issuer == \$i' >/dev/null && [[ \$issuer == https://\$(kc $HOST get route maas-keycloak -n $ns -o jsonpath='{.spec.host}')/realms/$realm ]]"
uat "realm discovery answers" "realm $realm is not serving: check the Keycloak deployment" \
  bash -c "curl -fsS \"\$issuer/.well-known/openid-configuration\" | jq -e --arg i \"\$issuer\" '.issuer == \$i' >/dev/null"
uat "authentication operator available" "clusteroperator authentication not Available after the OAuth patch" \
  bash -c "[[ \$(kc $HOST get clusteroperator authentication -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}') == True ]]"
uat "IdP client secret on the hub" "Secret osac-federation missing in openshift-config (bootstrap/37-hub-federation.sh)" \
  bash -c "kc $HOST get secret osac-federation -n openshift-config -o json | jq -e '.data.clientSecret' >/dev/null"
uat "provider-admin role exists" "ClusterRole ai-grid-provider-admin missing: the provider console isn't deployed (make console)" \
  bash -c "kc $HOST get clusterrole ai-grid-provider-admin >/dev/null"
uat "federated user bound" "ClusterRoleBinding ai-grid-osac-provider-admin missing (bootstrap/37-hub-federation.sh)" \
  bash -c "kc $HOST get clusterrolebinding ai-grid-osac-provider-admin >/dev/null"
uat "federated user is a provider admin" "oc auth can-i post /ai-grid/provider-console --as=$user says no: the binding's user name must be the preferred_username claim of realm $realm's users" \
  bash -c "[[ \$(kc $HOST auth can-i post /ai-grid/provider-console --as=$user) == yes ]]"
# The user check queries the realm itself (not just Secret ai-grid-test-users):
# a deleted realm user with the password Secret still present would otherwise
# pass. Admin login follows bootstrap/37's pattern — password piped, not argv.
kh=$(kc $HOST get route maas-keycloak -n $ns -o jsonpath='{.spec.host}')
au=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.username}' | base64 -d)
ap=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.password}' | base64 -d)
vtok=$(printf %s "$ap" | curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$au" \
  --data-urlencode password@- "https://$kh/realms/master/protocol/openid-connect/token" | jq -r .access_token); unset ap
uat "test user exists in the realm" "user $user missing in realm $realm (bootstrap/37-hub-federation.sh); the password is in Secret ai-grid-test-users" \
  bash -c "[[ -n \$vtok && \$vtok != null ]] && curl -fsS -H @<(printf 'Authorization: Bearer %s\n' \"\$vtok\") \"https://$kh/admin/realms/$realm/users?username=$user&exact=true\" | jq -e --arg u '$user' '.[0].username == \$u' >/dev/null"
unset vtok au
if kc $HOST get oauthclient ai-grid-proxy >/dev/null 2>&1; then
  uat "proxy OAuthClient has redirects" "OAuthClient ai-grid-proxy has no redirectURIs: OSAC_PROXY_REDIRECTS was empty when bootstrap/37-hub-federation.sh ran" \
    bash -c "kc $HOST get oauthclient ai-grid-proxy -o json | jq -e '.redirectURIs | length > 0' >/dev/null"
  uat "proxy OAuthClient secret kept" "Secret ai-grid-proxy-oauth missing in $ns (bootstrap/37-hub-federation.sh)" \
    bash -c "kc $HOST get secret ai-grid-proxy-oauth -n $ns -o json | jq -e '.data.clientSecret' >/dev/null"
fi
summary
