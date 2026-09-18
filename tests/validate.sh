#!/usr/bin/env bash
# Lightweight packaging checks, without requiring a YAML parser.
set -euo pipefail
ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/skills/go-pkg"
for file in SKILL.md agents/openai.yaml scripts/go-pkg.sh scripts/http.sh references/endpoints.json references/api.md; do
  [[ -s "$SKILL/$file" ]] || { printf 'FAIL: missing skill file: %s\n' "$file" >&2; exit 1; }
done
[[ $(head -n 1 "$SKILL/SKILL.md") == --- ]]
grep -q '^name: go-pkg$' "$SKILL/SKILL.md"
grep -q '^description: Use when' "$SKILL/SKILL.md"
[[ $(sed -n '/^description: /p' "$SKILL/SKILL.md" | wc -c) -lt 500 ]]
[[ $(wc -l < "$SKILL/SKILL.md") -lt 300 ]]
grep -q '\$go-pkg' "$SKILL/agents/openai.yaml"
jq -e '.api == "https://pkg.go.dev/v1" and (.routes | length == 8)' "$SKILL/references/endpoints.json" >/dev/null
for endpoint in search package module versions packages symbols imported-by vulns; do
  grep -q "\`$endpoint\`" "$SKILL/SKILL.md"
  bash "$SKILL/scripts/go-pkg.sh" "$endpoint" --help >/dev/null
done
while IFS= read -r script; do bash -n "$script"; done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*')
printf 'PASS: skill metadata, links, endpoint coverage, and Bash syntax\n'
