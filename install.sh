#!/usr/bin/env bash
# Copy the complete, reviewed local skill. Never download or overwrite files.
set -euo pipefail
fail() { printf 'install: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'HELP'
Usage: bash install.sh [--user | --project DIRECTORY | --dest DIRECTORY]
  --user               Install to $HOME/.agents/skills/go-pkg (default)
  --project DIRECTORY  Install to DIRECTORY/.agents/skills/go-pkg
  --dest DIRECTORY     Install to this exact directory, named go-pkg
Existing files, directories, and symlinks are never overwritten.
HELP
}
SOURCE=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/skills/go-pkg" && pwd)
MODE=user
VALUE=''
SELECTED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --user|--project|--dest)
      [[ $SELECTED -eq 0 ]] || fail 'choose exactly one installation scope'
      MODE=${1#--}; SELECTED=1; shift
      if [[ $MODE != user ]]; then
        [[ $# -gt 0 && -n $1 && $1 != --* ]] || fail "--$MODE requires a directory"
        VALUE=$1; shift
      fi ;;
    *) fail "unknown argument: $1" ;;
  esac
done
case "$MODE" in
  user) [[ -n ${HOME:-} ]] || fail 'HOME is not set'; DESTINATION="$HOME/.agents/skills/go-pkg" ;;
  project) [[ -d $VALUE ]] || fail 'project directory does not exist'; DESTINATION="$VALUE/.agents/skills/go-pkg" ;;
  dest) DESTINATION=$VALUE ;;
esac
DESTINATION=${DESTINATION%/}
[[ -n $DESTINATION && $(basename -- "$DESTINATION") == go-pkg ]] || fail 'destination must be a directory named go-pkg'
for dependency in bash curl jq; do command -v "$dependency" >/dev/null 2>&1 || fail "missing $dependency; install prerequisites from README.md"; done
[[ -f "$SOURCE/SKILL.md" && -f "$SOURCE/references/endpoints.json" ]] || fail 'incomplete source skill'
[[ ! -e $DESTINATION && ! -L $DESTINATION ]] || fail "destination already exists: $DESTINATION; back it up before updating"
PARENT=$(dirname -- "$DESTINATION")
mkdir -p "$PARENT"
PARENT=$(CDPATH= cd -P -- "$PARENT" && pwd)
DESTINATION="$PARENT/go-pkg"
[[ $DESTINATION != "$SOURCE" && $DESTINATION != "$SOURCE/"* ]] || fail 'cannot install inside the source skill'
CREATED=0
SUCCESS=0
cleanup() {
  local code=$?
  if [[ $CREATED -eq 1 && $SUCCESS -eq 0 ]]; then rm -rf "$DESTINATION"; fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# mkdir is the no-clobber gate, including a concurrent installation or symlink.
mkdir "$DESTINATION" || fail "could not create destination: $DESTINATION"
CREATED=1
cp -R "$SOURCE/." "$DESTINATION/"
chmod +x "$DESTINATION/scripts/go-pkg.sh" "$DESTINATION/scripts/http.sh"
SUCCESS=1
printf 'Installed go-pkg to %s\nInvoke $go-pkg in Codex; restart Codex if it is not discovered.\n' "$DESTINATION"
