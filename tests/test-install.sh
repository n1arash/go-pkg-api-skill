#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/go-pkg-install-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$ROOT/install.sh" ]] || fail 'missing installer'
# The distribution itself must be complete, not a test-only dummy SKILL.md.
[[ -f "$ROOT/skills/go-pkg/SKILL.md" ]] || fail 'missing installable skill'
mkdir -p "$TMP/home" "$TMP/project with spaces"
HOME="$TMP/home" bash "$ROOT/install.sh" > "$TMP/log"
DEST="$TMP/home/.agents/skills/go-pkg"
[[ -f "$DEST/SKILL.md" && -x "$DEST/scripts/go-pkg.sh" && -f "$DEST/references/endpoints.json" ]] || fail 'incomplete user installation'
bash "$DEST/scripts/go-pkg.sh" --help > /dev/null
printf 'keep me' > "$DEST/user-note"
if HOME="$TMP/home" bash "$ROOT/install.sh" > "$TMP/log" 2>&1; then fail 'overwrote an existing installation'; fi
[[ $(cat "$DEST/user-note") == 'keep me' ]] || fail 'changed existing content'
bash "$ROOT/install.sh" --project "$TMP/project with spaces" > "$TMP/log"
[[ -f "$TMP/project with spaces/.agents/skills/go-pkg/SKILL.md" ]] || fail 'project installation failed'
bash "$ROOT/install.sh" --dest "$TMP/custom parent/go-pkg" > "$TMP/log"
[[ -f "$TMP/custom parent/go-pkg/SKILL.md" ]] || fail 'custom installation failed'
mkdir "$TMP/link-parent"
ln -s "$TMP/missing" "$TMP/link-parent/go-pkg"
if bash "$ROOT/install.sh" --dest "$TMP/link-parent/go-pkg" > "$TMP/log" 2>&1; then fail 'overwrote a symlink'; fi
if bash "$ROOT/install.sh" --project "$TMP/absent" > "$TMP/log" 2>&1; then fail 'accepted missing project'; fi
if bash "$ROOT/install.sh" --dest > "$TMP/log" 2>&1; then fail 'accepted missing destination'; fi
if bash "$ROOT/install.sh" --dest '' > "$TMP/log" 2>&1; then fail 'accepted empty destination'; fi
if bash "$ROOT/install.sh" --dest / > "$TMP/log" 2>&1; then fail 'accepted filesystem root'; fi
if bash "$ROOT/install.sh" --user --project "$TMP" > "$TMP/log" 2>&1; then fail 'accepted conflicting scopes'; fi
if bash "$ROOT/install.sh" --unknown > "$TMP/log" 2>&1; then fail 'accepted unknown option'; fi
printf 'PASS: 13 installer checks\n'
