#!/usr/bin/env bash
# Emits the OSAC UI proxy's grids config (grids.json, GRIDS_CONFIG_FILE on the OSAC side) from this
# hub's live state: the provider console route, the hub's OAuth server, the proxy OAuthClient secret
# that bootstrap/37-hub-federation.sh keeps, and the federated IdP's name. One AI Grid hub per
# checkout: for several grids, run this per hub checkout with the same GRIDS_OUT — entries merge by
# grid ID (OSAC-6437 Phase 4: multiple grids wired by config, not hand-written JSON).
#
#   GRID_ID=sno-01 GRIDS_OUT=/tmp/grids.json bash bootstrap/38-osac-grids-config.sh
#
# GRID_ID is the OSAC UI's name for this hub and must match the callback URI this hub's OAuthClient
# was created with (OSAC_PROXY_REDIRECTS at make federation time:
# https://<osac-ui-host>/api/grids/<GRID_ID>/callback). Without GRIDS_OUT the single entry prints
# to stdout — it carries the clientSecret, so it belongs in the operator's terminal or the file,
# never in a log; the file must never be committed.
source "$(dirname "$0")/lib.sh"
[[ -n ${GRID_ID:-} ]] || die "GRID_ID is required: the OSAC UI's name for this hub (e.g. GRID_ID=sno-01)"
[[ $GRID_ID =~ ^[a-zA-Z0-9._-]+$ ]] || die "GRID_ID must be URL-safe (letters, digits, dot, dash, underscore): the OSAC proxy rejects anything else"
console_host=$(kc $HOST get route ai-grid-provider-console -n ai-grid -o jsonpath='{.spec.host}')
[[ -n $console_host ]] || die "route ai-grid-provider-console in ai-grid missing: run make console first"
domain=$(kc $HOST get ingresses.config cluster -o jsonpath='{.spec.domain}')
[[ -n $domain ]] || die "ingresses.config cluster domain missing: not an OpenShift hub?"
idp=$(kc $HOST get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.osacIdPName}')
idp=${idp:-osac}
ps=$(kc $HOST get secret ai-grid-proxy-oauth -n $KEYCLOAK_NS -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d || true)
[[ -n $ps ]] || die "Secret ai-grid-proxy-oauth missing in $KEYCLOAK_NS: run OSAC_PROXY_REDIRECTS=... make federation first (the callback must name GRID_ID $GRID_ID)"
# jq builds the entry; the secret reaches it through the environment, never argv.
entry=$(PS=$ps jq -nc --arg id "$GRID_ID" --arg hub "https://$console_host" \
  --arg oauth "https://oauth-openshift.$domain" --arg idp "$idp" \
  '{id:$id, hubURL:$hub, oauthURL:$oauth, clientID:"ai-grid-proxy", clientSecret:env.PS, idp:$idp}')
unset ps PS
if [[ -z ${GRIDS_OUT:-} ]]; then
  printf '%s\n' "$entry"
  log "grid $GRID_ID entry printed (redirect URI: https://<osac-ui-host>/api/grids/$GRID_ID/callback)"
  exit 0
fi
# Merge by grid ID: an earlier entry for this grid is replaced, not duplicated.
# An empty or absent file starts fresh (jq on an empty input writes nothing,
# so the file is seeded before the merge). The entry — which carries the
# clientSecret — reaches jq through the environment, never argv (ps shows argv).
[[ -s $GRIDS_OUT ]] || printf '{"grids":[]}' >"$GRIDS_OUT"
tmp=$GRIDS_OUT.tmp
ENTRY=$entry jq '.grids = ((.grids // []) | map(select(.id != ($ENV.ENTRY | fromjson).id)) + [($ENV.ENTRY | fromjson)])' \
  "$GRIDS_OUT" >"$tmp"
mv "$tmp" "$GRIDS_OUT"
unset entry ENTRY
log "grid $GRID_ID written to $GRIDS_OUT ($(jq '.grids | length' "$GRIDS_OUT") grid(s)); hand it to the OSAC UI proxy as GRIDS_CONFIG_FILE"
