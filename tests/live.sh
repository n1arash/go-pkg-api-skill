#!/usr/bin/env bash
# Explicit opt-in production smoke tests. Requires internet, Bash, curl, jq.
set -euo pipefail
ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/go-pkg/scripts/go-pkg.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/go-pkg-live.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export GO_PKG_BASE_URL=https://pkg.go.dev/v1
export GO_PKG_RETRIES=${GO_PKG_RETRIES:-1}
export GO_PKG_TIMEOUT=${GO_PKG_TIMEOUT:-20}
bash "$CLI" spec > "$TMP/openapi.yaml"
bash "$ROOT/tests/check-contract.sh" "$TMP/openapi.yaml"
check() {
  local command=$1 expression=$2
  shift 2
  bash "$CLI" "$command" "$@" > "$TMP/response.json"
  jq -e "$expression" "$TMP/response.json" >/dev/null
  printf 'PASS: live %s\n' "$command"
  sleep 1
}
check search '(.items | type) == "array"' uuid --limit 1
check package '.path == "github.com/google/uuid" and .version == "v1.6.0" and (.docs | type) == "string"' github.com/google/uuid --version v1.6.0 --doc md --examples --imports --licenses
check module '.path == "github.com/google/uuid" and .version == "v1.6.0"' github.com/google/uuid --version v1.6.0 --readme --licenses
check versions '(.items | type) == "array"' github.com/google/uuid --limit 1
check packages '(.packages | type) == "object"' github.com/google/uuid --version v1.6.0 --limit 1
check symbols '(.symbols | type) == "object"' github.com/google/uuid --version v1.6.0 --limit 1
check imported-by '(.importedBy | type) == "object"' github.com/google/uuid --limit 1
check vulns '.items == null or (.items | type) == "array"' github.com/google/uuid --version v1.6.0 --limit 1
