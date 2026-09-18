#!/usr/bin/env bash
# Compare every HTTP operation and query parameter, not just endpoint counts.
set -euo pipefail
ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# -eq 1 && -r $1 ]] || { printf 'Usage: bash tests/check-contract.sh OPENAPI_FILE\n' >&2; exit 2; }
if ! jq -e 'type == "object" and (.paths | type == "object")' "$1" >/dev/null 2>&1; then
  printf 'Expected a JSON-formatted OpenAPI document. If upstream switches to YAML, convert it to JSON with a trusted local tool for this development check.\n' >&2
  exit 2
fi
jq -e --slurpfile manifest "$ROOT/skills/go-pkg/references/endpoints.json" '
  def methods: ["get","put","post","delete","options","head","patch","trace"];
  def actual:
    [.paths | to_entries[] | . as $route | .value | to_entries[] |
      select(.key as $key | methods | index($key)) |
      {path:$route.key, method:.key, operationId:.value.operationId,
       parameters: ([.value.parameters[]? | select(.in == "query") |
         {key:.name,value:.schema.type}] | from_entries)}] | sort_by(.path,.method);
  def expected:
    [$manifest[0].routes[] | {path,method:"get",operationId,parameters}] | sort_by(.path,.method);
  (actual) as $actual | (expected) as $expected |
  if ([.servers[]?.url] | index($manifest[0].api)) == null then
    error("OpenAPI server does not include the configured v1 base URL")
  elif $actual != $expected then
    error("Contract drift: reviewed=" + ($expected|tojson) + " upstream=" + ($actual|tojson))
  else true end
' "$1" >/dev/null
printf 'PASS: upstream operations and query parameters match the reviewed contract\n'
