#!/usr/bin/env bash
# Internal library, sourced by go-pkg.sh after configuration validation.

http_get() {
  local destination=$1 token=$2 token_set=$3 validate_json=$4 status code
  local -a arguments
  arguments=(--silent --show-error --globoff --location --max-redirs 3
    --proto "$PROTOCOLS" --proto-redir "$PROTOCOLS"
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT"
    --retry "$RETRIES" --retry-max-time 60
    --header 'Accept: application/json' --user-agent 'go-pkg-skill/1.0'
    --output "$destination" --write-out '%{http_code}')
  [[ $token_set -eq 0 ]] || arguments+=(--data-urlencode "token=$token")
  # -q MUST be first: ignore ~/.curlrc so it cannot alter method, TLS or output.
  # curl retries transient HTTP failures and honors Retry-After on curl >= 7.66.
  if status=$(curl -q "${arguments[@]}" "${QUERY_ARGS[@]}" --url "$URL"); then
    :
  else
    code=$?
    fail "$code" "request failed (curl exit $code)"
  fi
  [[ $status =~ ^[0-9]{3}$ ]] || fail 65 'curl returned an invalid HTTP status'
  case "$status" in
    2??) ;;
    *)
      printf 'go-pkg: HTTP %s\n' "$status" >&2
      # Preserve candidates/fixes; quote non-JSON bodies to avoid terminal escapes.
      if jq -e -s 'length == 1 and (.[0] | type == "object")' "$destination" >/dev/null 2>&1; then
        jq . "$destination" >&2
      else
        jq -Rs '.[0:2000]' "$destination" >&2
      fi
      exit 22 ;;
  esac
  if [[ $validate_json -eq 1 ]]; then
    jq -e -s 'length == 1 and (.[0] | type == "object")' "$destination" >/dev/null 2>&1 || fail 65 'expected exactly one JSON object from the API'
  fi
}

fetch_all() {
  local page=0 next_token token=$TOKEN token_set=$TOKEN_SET
  printf '[]\n' > "$WORK/seen"
  if [[ $token_set -eq 1 && -n $token ]]; then
    jq -n --arg token "$token" '[$token]' > "$WORK/seen"
  fi
  while :; do
    http_get "$WORK/page" "$token" "$token_set" 1
    # Empty lists can be omitted or null by Go's JSON encoder.
    jq -e --argjson path "$PAGE_PATH" '
      getpath($path) as $p | ($p | type) == "object"
      and ($p.items == null or ($p.items | type) == "array")
      and ($p.nextPageToken == null or ($p.nextPageToken | type) == "string")
    ' "$WORK/page" >/dev/null || fail 65 'invalid paginated response shape'
    if [[ $page -eq 0 ]]; then
      jq --argjson path "$PAGE_PATH" '
        setpath($path + ["items"]; (getpath($path + ["items"]) // []))
      ' "$WORK/page" > "$WORK/aggregate"
    else
      jq -e -s '.[0] as $a | .[1] as $b |
        all(["modulePath", "version"][]; . as $k |
          $a[$k] == null or $b[$k] == null or $a[$k] == $b[$k])
      ' "$WORK/aggregate" "$WORK/page" >/dev/null || fail 65 'module/version changed between pages; restart with a pinned version'
      jq -s --argjson path "$PAGE_PATH" '
        .[0] as $a | .[1] as $b | $a |
        setpath($path + ["items"];
          (($a | getpath($path + ["items"])) + ($b | getpath($path + ["items"]) // [])))
      ' "$WORK/aggregate" "$WORK/page" > "$WORK/merged"
      mv "$WORK/merged" "$WORK/aggregate"
    fi
    page=$((page + 1))
    # A sentinel preserves trailing newlines in opaque tokens during substitution.
    next_token=$(jq -j --argjson path "$PAGE_PATH" 'getpath($path + ["nextPageToken"]) // ""' "$WORK/page" && printf '.')
    next_token=${next_token%.}
    [[ -n $next_token ]] || break
    [[ $page -lt $MAX_PAGES ]] || fail 75 "pagination exceeds --max-pages $MAX_PAGES; raise the cap or use --token manually"
    if jq -e --arg token "$next_token" 'index($token) != null' "$WORK/seen" >/dev/null; then
      fail 75 'repeated pagination token; refusing an infinite loop'
    fi
    jq --arg token "$next_token" '. + [$token]' "$WORK/seen" > "$WORK/seen-next"
    mv "$WORK/seen-next" "$WORK/seen"
    token=$next_token
    token_set=1
  done
  # Emit only after EVERY page succeeds. Never print partial results on failure.
  jq --argjson path "$PAGE_PATH" 'setpath($path + ["nextPageToken"]; "")' "$WORK/aggregate"
}
