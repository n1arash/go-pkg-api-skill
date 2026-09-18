#!/usr/bin/env bash
# Synthetic fixtures test drift detection; they do not verify live upstream.
set -euo pipefail
ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/go-pkg-contract.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
jq '{openapi:"3.0.3",servers:[{url:.api}],paths:
  (.routes | to_entries | map({key:.value.path,value:{get:{operationId:.value.operationId,
  parameters:(.value.parameters | to_entries | map({in:"query",name:.key,schema:{type:.value}}))}}}) | from_entries)}' \
  "$ROOT/skills/go-pkg/references/endpoints.json" > "$TMP/base.json"
bash "$ROOT/tests/check-contract.sh" "$TMP/base.json" >/dev/null
count=1
while IFS= read -r mutation; do
  jq "$mutation" "$TMP/base.json" > "$TMP/changed.json"
  if bash "$ROOT/tests/check-contract.sh" "$TMP/changed.json" > "$TMP/out" 2>&1; then
    printf 'FAIL: undetected contract mutation: %s\n' "$mutation" >&2; exit 1
  fi
  count=$((count + 1))
done <<'MUTATIONS'
del(.paths["/search"])
.paths["/new"]={get:{operationId:"getNew",parameters:[]}}
.paths["/search"].post={operationId:"postSearch",parameters:[]}
.paths["/search"].get.parameters += [{in:"query",name:"new",schema:{type:"string"}}]
.paths["/search"].get.parameters[0].schema.type="boolean"
.paths["/search"].get.operationId="changed"
.servers[0].url="https://example.test/v2"
MUTATIONS
printf 'PASS: %s synthetic contract-checker checks\n' "$count"
