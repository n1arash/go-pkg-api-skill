#!/usr/bin/env bash
# Offline black-box tests: the curl process is replaced, not the CLI logic.
set -euo pipefail
ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/go-pkg/scripts/go-pkg.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/go-pkg-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/tmp" "$TMP/responses"
export MOCK_LOG="$TMP/curl.jsonl" MOCK_COUNTER="$TMP/count" MOCK_RESPONSES="$TMP/responses"
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$MOCK_LOG"
number=0
[[ ! -f "$MOCK_COUNTER" ]] || number=$(cat "$MOCK_COUNTER")
number=$((number + 1))
printf '%s' "$number" > "$MOCK_COUNTER"
out=''
while [[ $# -gt 0 ]]; do
  case "$1" in --output) out=$2; shift 2 ;; *) shift ;; esac
done
[[ -n "$out" ]] || { printf 'mock: no output file\n' >&2; exit 99; }
if [[ -f "$MOCK_RESPONSES/$number.json" ]]; then
  cat "$MOCK_RESPONSES/$number.json" > "$out"
else
  printf '{"ok":true}\n' > "$out"
fi
if [[ -f "$MOCK_RESPONSES/$number.code" ]]; then
  exit "$(cat "$MOCK_RESPONSES/$number.code")"
fi
if [[ -f "$MOCK_RESPONSES/$number.status" ]]; then
  cat "$MOCK_RESPONSES/$number.status"
else
  printf '200'
fi
MOCK
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export TMPDIR="$TMP/tmp"
unset GO_PKG_BASE_URL GO_PKG_TIMEOUT GO_PKG_CONNECT_TIMEOUT GO_PKG_RETRIES || true
count=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$TMP/err" >&2 2>/dev/null || true; exit 1; }
pass() { count=$((count + 1)); }
reset() { rm -f "$TMP/responses/"* "$MOCK_LOG" "$MOCK_COUNTER"; }
run() {
  local expected=$1 actual=0
  shift
  bash "$CLI" "$@" > "$TMP/out" 2> "$TMP/err" || actual=$?
  [[ $actual -eq $expected ]] || fail "expected exit $expected, got $actual: $*"
}
json() { jq -e "$1" "$TMP/out" > /dev/null || fail "stdout assertion: $1"; }
args_have() { jq -se --arg value "$1" 'all(.[]; index($value) != null)' "$MOCK_LOG" > /dev/null || fail "missing curl argument: $1"; }
no_output() { [[ ! -s "$TMP/out" ]] || fail 'unexpected stdout on failure'; }
no_request() { [[ ! -f "$MOCK_LOG" ]] || fail 'invalid invocation made a request'; }
[[ -f "$CLI" ]] || fail 'expected the go-pkg CLI implementing all eight endpoints'

run 0 --help; grep -q 'go-pkg' "$TMP/out" || fail 'help missing'; pass
for endpoint in package module versions packages search symbols imported-by vulns; do
  reset
  if [[ $endpoint == search ]]; then
    run 0 "$endpoint" 'uuid & context'
    args_have 'q=uuid & context'
    args_have 'https://pkg.go.dev/v1/search'
  else
    run 0 "$endpoint" github.com/Acme/Thing/v2
    args_have "https://pkg.go.dev/v1/$endpoint/github.com/Acme/Thing/v2"
  fi
  json '.ok == true'
  args_have '-q'; args_have '--get'; args_have '--globoff'
  args_have '--retry'; args_have '--retry-max-time'; args_have '--max-time'
  args_have '--proto-redir'; pass
  run 0 "$endpoint" --help; pass
done
# Independent list of every OpenAPI query parameter and its CLI value.
while IFS='|' read -r endpoint parameters; do
  for parameter in $parameters; do
    reset
    case "$parameter" in
      limit) value=2 ;;
      licenses|readme|examples|imports|pseudo) value=false ;;
      doc) value=markdown ;;
      *) value='a+b & c/="quoted"' ;;
    esac
    if [[ $endpoint == search ]]; then
      run 0 "$endpoint" "--$parameter" "$value"
    else
      run 0 "$endpoint" net/http "--$parameter" "$value"
    fi
    args_have "$parameter=$value"; pass
  done
done <<'PARAMETERS'
package|module version goos goarch doc examples imports licenses
module|version licenses readme
versions|limit token filter pseudo
packages|version limit token filter
search|q symbol limit token filter
symbols|module version goos goarch limit token filter
imported-by|module version limit token filter
vulns|module version limit token filter
PARAMETERS
reset; run 0 package fmt --doc=md --examples --imports=true --licenses false
args_have 'doc=md'; args_have 'examples=true'; args_have 'imports=true'; args_have 'licenses=false'; pass
reset; run 0 search --q='@/x & "y"' --symbol=New; args_have 'q=@/x & "y"'; pass
reset; run 0 package 'example.com/a?b#c'; args_have 'https://pkg.go.dev/v1/package/example.com/a%3Fb%23c'; pass

for endpoint in search versions packages symbols imported-by vulns; do
  reset
  case "$endpoint" in packages) key=packages ;; symbols) key=symbols ;; imported-by) key=importedBy ;; *) key='' ;; esac
  for page in 1 2; do
    if [[ $page == 1 ]]; then token='next +/="&' ; item=1; else token=''; item=2; fi
    jq -n --arg key "$key" --arg token "$token" --argjson item "$item" \
      '{items:[$item],nextPageToken:$token,total:-1} | if $key == "" then . else {modulePath:"example.com/a",version:"v1.0.0",($key):.} end' > "$TMP/responses/$page.json"
  done
  run 0 "$endpoint" example.com/a --limit 1 --filter 'name != "bad"' --all
  jq -e --arg key "$key" '(if $key == "" then . else .[$key] end) | .items == [1,2] and .nextPageToken == "" and .total == -1' "$TMP/out" >/dev/null || fail "pagination: $endpoint"
  args_have 'limit=1'; args_have 'filter=name != "bad"'
  jq -se 'length == 2 and (.[1] | index("token=next +/=\"&") != null)' "$MOCK_LOG" >/dev/null || fail 'token not preserved'
  pass
done
# Opaque tokens must retain trailing newlines, not shell-trim them.
reset
printf '{"items":[1],"nextPageToken":"line\\n"}' > "$TMP/responses/1.json"
printf '{"items":[2]}' > "$TMP/responses/2.json"
run 0 search x --all
jq -se '.[1] | index("token=line\n") != null' "$MOCK_LOG" >/dev/null || fail 'trimmed an opaque token'
pass
reset
printf '{"items":[],"nextPageToken":"again"}' > "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/2.json"
run 75 search x --all; no_output; pass
reset
printf '{"items":[1],"nextPageToken":"next"}' > "$TMP/responses/1.json"
run 75 search x --all --max-pages 1; no_output; [[ $(cat "$MOCK_COUNTER") == 1 ]] || fail 'page cap'; pass
reset
printf '{"items":[1],"nextPageToken":"next"}' > "$TMP/responses/1.json"
printf '{"message":"unavailable"}' > "$TMP/responses/2.json"
printf 503 > "$TMP/responses/2.status"
run 22 search x --all; no_output; pass
reset
printf '{"items":null}' > "$TMP/responses/1.json"
run 0 search x --all; json '.items == []'; pass
reset
printf '{"items":"wrong","nextPageToken":""}' > "$TMP/responses/1.json"
run 65 search x --all; no_output; pass
reset
printf '{"items":[],"nextPageToken":12}' > "$TMP/responses/1.json"
run 65 search x --all; no_output; pass
reset
printf '{"code":400,"message":"ambiguous","candidates":[{"modulePath":"a/b"}],"fixes":["use module"]}' > "$TMP/responses/1.json"
printf 400 > "$TMP/responses/1.status"
run 22 package a/b/c; no_output; grep -q 'candidates' "$TMP/err" || fail 'lost ambiguity candidates'; pass
for body in 'not JSON' 'null' '[]' '{}{}' ''; do
  reset; printf '%s' "$body" > "$TMP/responses/1.json"
  run 65 package fmt; no_output; pass
done
reset; printf 6 > "$TMP/responses/1.code"; run 6 package fmt; no_output; pass
reset; run 0 spec; args_have 'https://pkg.go.dev/v1/openapi.yaml'; pass

# Invalid inputs must be rejected before curl is invoked.
while IFS='|' read -r code command argument flag value; do
  reset
  if [[ -n "$flag" ]]; then run "$code" "$command" "$argument" "$flag" "$value"; else run "$code" "$command" "$argument"; fi
  no_request; pass
done <<'INVALID'
2|unknown|x||
2|package|||
2|package|../fmt||
2|package|fmt@v1||
2|package|a//b||
2|package|https://evil.test||
2|package|fmt|--readme|true
2|module|x|--module|x
2|versions|x|--version|v1
2|symbols|fmt|--doc|md
2|search|x|--limit|0
2|search|x|--limit|-1
2|search|x|--limit|oops
2|package|fmt|--doc|xml
2|package|fmt|--imports|maybe
2|search|x|--unknown|a
INVALID
reset; run 2 search a b; no_request; pass
reset; run 2 search a --q b; no_request; pass
reset; run 2 package fmt --version; no_request; pass
reset; run 2 package fmt --all; no_request; pass
reset; run 2 search x --max-pages 2; no_request; pass
reset; run 2 search x --all --max-pages=0; no_request; pass
reset; GO_PKG_BASE_URL='http://evil.test/v1' run 2 search x; no_request; pass
reset; GO_PKG_BASE_URL='https://evil.test/v1?leak=x' run 2 search x; no_request; pass
reset; GO_PKG_TIMEOUT=oops run 2 search x; no_request; pass
reset; GO_PKG_BASE_URL='http://127.0.0.1:9876/v1/' run 0 search x
args_have 'http://127.0.0.1:9876/v1/search'; pass
[[ -z $(find "$TMP/tmp" -mindepth 1 -print) ]] || fail 'temporary files leaked'
pass
printf 'PASS: %s offline CLI checks\n' "$count"
