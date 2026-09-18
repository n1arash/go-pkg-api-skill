#!/usr/bin/env bash
# Portable, read-only pkg.go.dev v1 client. Bash 3.2+, curl 7.66+, jq 1.6+.
set -euo pipefail

fail() { local code=$1; shift; printf 'go-pkg: %s\n' "$*" >&2; exit "$code"; }
usage() {
  cat <<'HELP'
Usage: bash go-pkg.sh COMMAND [PATH|QUERY] [OPTIONS]

  search       Find public packages or symbols
  package      Package metadata and optional docs/examples/imports/licenses
  module       Module metadata, go.mod, optional README/licenses
  versions     Module versions, retractions, and deprecations
  packages     Packages contained in a module
  symbols      Package symbol inventory
  imported-by  Indexed importers outside the package's module
  vulns        Known Go vulnerability database findings
  spec         Download the upstream OpenAPI document (raw output)

Use COMMAND --help for its exact options. Query options accept --key VALUE
or --key=VALUE. Boolean options also accept a bare flag meaning true.
List commands accept --all and --max-pages N (default 20). Without --all,
return one page unchanged. With --all, merge items in the original JSON shape.
PATH is an unescaped import/module path; use --version, not path@version.
Search accepts a quoted positional query or --q; --symbol may be used alone.
JSON goes to stdout; errors go to stderr with a nonzero exit status.

Examples:
  bash go-pkg.sh search 'uuid' --limit 5
  bash go-pkg.sh package github.com/google/uuid --version v1.6.0 --doc md --examples
  bash go-pkg.sh packages golang.org/x/time --all
HELP
}
[[ $# -gt 0 ]] || { usage; exit 0; }
case "$1" in --help|-h|help) usage; exit 0 ;; esac
for dependency in curl jq mktemp; do
  command -v "$dependency" >/dev/null 2>&1 || fail 3 "missing dependency: $dependency (see README.md)"
done
SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="$SCRIPT_DIR/../references/endpoints.json"
[[ -r "$MANIFEST" ]] || fail 3 'missing references/endpoints.json; install the whole skill directory'
COMMAND=$1
shift
if [[ $COMMAND == spec ]]; then
  if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Usage: bash go-pkg.sh spec\nDownload the upstream OpenAPI document, without JSON reformatting.\n'
    exit 0
  fi
  [[ $# -eq 0 ]] || fail 2 'spec takes no options'
  ROUTE='{"path":"/openapi.yaml","pathKind":null,"parameters":{},"pagination":null}'
else
  ROUTE=$(jq -ce --arg command "$COMMAND" '.routes[$command] // empty' "$MANIFEST") || fail 2 "unknown command: $COMMAND"
fi
PAGE_PATH=$(printf '%s' "$ROUTE" | jq -c '.pagination')
PATH_KIND=$(printf '%s' "$ROUTE" | jq -r '.pathKind // empty')
command_help() {
  printf 'Usage: bash go-pkg.sh %s %s [OPTIONS]\n' "$COMMAND" "${PATH_KIND:+PATH}"
  printf '%s' "$ROUTE" | jq -r '.summary, (.parameters | to_entries[] | "  --\(.key) \(.value)")'
  if [[ $PAGE_PATH != null ]]; then
    printf '  --all                Fetch all pages; preserve the response shape\n  --max-pages INTEGER  Safety cap with --all (default 20; maximum 10000)\n'
  fi
  printf 'Boolean flags accept true/false; a bare boolean flag means true.\n'
}
QUERY_ARGS=(--get)
SEEN='|'
PATH_VALUE=''
POSITIONAL_SET=0
TOKEN=''
TOKEN_SET=0
ALL=0
MAX_PAGES=20
MAX_PAGES_SET=0
OPTIONS_DONE=0
# Bound integers before using Bash arithmetic (no octal or overflow surprises).
positive_integer() { [[ $1 =~ ^[1-9][0-9]*$ && ${#1} -le 9 ]]; }
set_query() {
  local key=$1 value=$2
  [[ $SEEN != *"|$key|"* ]] || fail 2 "duplicate option: --$key"
  SEEN="$SEEN$key|"
  if [[ $key == token ]]; then TOKEN=$value; TOKEN_SET=1
  else QUERY_ARGS+=(--data-urlencode "$key=$value")
  fi
}
while [[ $# -gt 0 ]]; do
  if [[ $OPTIONS_DONE -eq 0 ]]; then
    case "$1" in
      --help|-h) command_help; exit 0 ;;
      --) OPTIONS_DONE=1; shift; continue ;;
      --all) [[ $ALL -eq 0 ]] || fail 2 'duplicate --all'; ALL=1; shift; continue ;;
      --*)
        raw=$1; key=${raw%%=*}; key=${key#--}; inline=0
        [[ $raw != *=* ]] || inline=1
        if [[ $key == max-pages ]]; then
          [[ $MAX_PAGES_SET -eq 0 ]] || fail 2 'duplicate --max-pages'
          kind=integer
        else
          kind=$(printf '%s' "$ROUTE" | jq -r --arg key "$key" '.parameters[$key] // empty')
          [[ -n $kind ]] || fail 2 "$COMMAND does not support --$key; use $COMMAND --help"
        fi
        shift
        if [[ $inline -eq 1 ]]; then value=${raw#*=}
        elif [[ $kind == boolean ]]; then
          value=true
          if [[ ${1:-} == true || ${1:-} == false ]]; then value=$1; shift; fi
        else
          [[ $# -gt 0 && $1 != --* ]] || fail 2 "--$key requires a value"
          value=$1; shift
        fi
        case "$kind" in
          integer) positive_integer "$value" || fail 2 "--$key requires a positive integer (up to 9 digits)" ;;
          boolean) [[ $value == true || $value == false ]] || fail 2 "--$key requires true or false" ;;
        esac
        if [[ $key == doc ]]; then
          case "$value" in text|html|md|markdown) ;; *) fail 2 '--doc must be text, html, md, or markdown' ;; esac
        fi
        if [[ $key == max-pages ]]; then MAX_PAGES=$value; MAX_PAGES_SET=1
        else set_query "$key" "$value"
        fi
        continue ;;
      -*) fail 2 "unknown option: $1 (use -- before a query starting with '-')" ;;
    esac
  fi
  [[ $POSITIONAL_SET -eq 0 ]] || fail 2 'quote multiword queries; only one positional argument is accepted'
  POSITIONAL_SET=1
  if [[ $COMMAND == search ]]; then set_query q "$1"; else PATH_VALUE=$1; fi
  shift
done
[[ $MAX_PAGES_SET -eq 0 || $ALL -eq 1 ]] || fail 2 '--max-pages requires --all'
[[ $ALL -eq 0 || $PAGE_PATH != null ]] || fail 2 "$COMMAND is not paginated; --all is unsupported"
[[ $MAX_PAGES -le 10000 ]] || fail 2 '--max-pages must not exceed 10000'
if [[ -n $PATH_KIND ]]; then
  [[ -n $PATH_VALUE && $PATH_VALUE != /* && $PATH_VALUE != */ && $PATH_VALUE != *//* && $PATH_VALUE != *'@'* && $PATH_VALUE != *'\'* ]] || fail 2 'provide a plain import/module path; use --version separately'
  [[ ! $PATH_VALUE =~ [[:space:][:cntrl:]] ]] || fail 2 'paths cannot contain whitespace or control characters'
  case "/$PATH_VALUE/" in */./*|*/../*) fail 2 'paths cannot contain . or .. segments' ;; esac
fi
BASE_URL=${GO_PKG_BASE_URL:-https://pkg.go.dev/v1}
BASE_URL=${BASE_URL%/}
# Do not allow credentials, queries, fragments, or arbitrary cleartext servers.
HTTPS_PATTERN='^https://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$'
LOCAL_PATTERN='^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/[^?#[:space:]]*)?$'
[[ $BASE_URL =~ $HTTPS_PATTERN || $BASE_URL =~ $LOCAL_PATTERN ]] || fail 2 'GO_PKG_BASE_URL must be HTTPS, or HTTP on loopback, without credentials/query/fragment'
TIMEOUT=${GO_PKG_TIMEOUT:-30}
CONNECT_TIMEOUT=${GO_PKG_CONNECT_TIMEOUT:-10}
RETRIES=${GO_PKG_RETRIES:-2}
positive_integer "$TIMEOUT" && [[ $TIMEOUT -le 3600 ]] || fail 2 'GO_PKG_TIMEOUT must be an integer from 1 to 3600'
positive_integer "$CONNECT_TIMEOUT" && [[ $CONNECT_TIMEOUT -le 3600 ]] || fail 2 'GO_PKG_CONNECT_TIMEOUT must be an integer from 1 to 3600'
[[ $RETRIES =~ ^(0|[1-9]|10)$ ]] || fail 2 'GO_PKG_RETRIES must be an integer from 0 to 10'
PROTOCOLS='=https'
[[ $BASE_URL != http://* ]] || PROTOCOLS='=http,https'
ENCODED_PATH=$(jq -nr --arg path "$PATH_VALUE" '$path | split("/") | map(@uri) | join("/")')
ROUTE_PATH=$(printf '%s' "$ROUTE" | jq -r '.path')
URL="$BASE_URL${ROUTE_PATH/\{path\}/$ENCODED_PATH}"
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/go-pkg.XXXXXX") || fail 3 'could not create a temporary directory'
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck source=http.sh
source "$SCRIPT_DIR/http.sh"
if [[ $COMMAND == spec ]]; then
  http_get "$WORK/body" "$TOKEN" "$TOKEN_SET" 0
  cat "$WORK/body"
elif [[ $ALL -eq 1 ]]; then
  fetch_all
else
  http_get "$WORK/body" "$TOKEN" "$TOKEN_SET" 1
  jq . "$WORK/body"
fi
