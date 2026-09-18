# go-pkg — Go package research for Codex

An installable Agent Skill that helps coding agents verify public Go package APIs before using them. Invoke **`$go-pkg`** in Codex. Its portable CLI implements **all eight GET operations and all 41 query-parameter occurrences** in the reviewed pkg.go.dev v1 OpenAPI contract, using Bash, curl, and jq.

This is a read-only documentation client, not a package installer, Go compiler, MCP server, or vulnerability scanner. No Go, Python, Node.js, API key, or background service is needed at runtime.

## Install

### Requirements

Bash **3.2+**, curl **7.66+**, jq **1.6+**, HTTPS access to `pkg.go.dev`, and standard Unix utilities (`mktemp`, `dirname`, `cp`, `chmod`, `mkdir`, `mv`, `rm`, `cat`). Git is needed only to clone/update this repository. curl must have a working CA trust store; the client never disables TLS verification.

The scripts target Linux, macOS, and Windows **through WSL or Git Bash** with those dependencies installed. They are not native PowerShell scripts. Check versions with `bash --version`, `curl --version`, and `jq --version`. On Debian/Ubuntu, install missing dependencies with `sudo apt-get install bash curl jq git`; on macOS, `brew install jq` supplies jq when Bash and curl are already available.

### User-wide installation

Clone and review the files before running the local installer:

```bash
git clone https://github.com/n1arash/go-pkg-api-skill.git
cd go-pkg-api-skill
bash install.sh --user
```

This copies only `skills/go-pkg/` to **`$HOME/.agents/skills/go-pkg`**, a user skill location supported by Codex. The repository may be private: authenticate Git with an account that has access, or use the SSH clone URL `git@github.com:n1arash/go-pkg-api-skill.git`. A GitHub token is not needed for subsequent public pkg.go.dev queries.

The installer does not download or execute remote code, overwrite existing installations, or modify shell profiles. For older/custom tool configurations, use `--dest` to choose the skill directory explicitly.

### Project-scoped or custom installation

```bash
# The project directory must already exist.
bash install.sh --project /path/to/project
# Installs into /path/to/project/.agents/skills/go-pkg

# An exact destination, whose final directory name must be go-pkg:
bash install.sh --dest /path/to/skills/go-pkg
```

Keep the **whole directory**, including `scripts/` and `references/`; copying `SKILL.md` alone is insufficient. Paths containing spaces are supported when quoted.

### Install through Codex

In a Codex environment with the built-in skill installer and access to this repository:

```text
$skill-installer install the skill at skills/go-pkg from n1arash/go-pkg-api-skill
```

This uses Codex's installer, not this repository's `install.sh`. Private repository access must be available to that environment. The explicit local installation above works independently of the built-in installer.

Codex normally detects skill changes; restart it when the skill is not visible. Use `/skills` or type `$` and select `go-pkg`. The standard skill metadata also supports implicit activation for matching Go research tasks. See the [official Codex skill documentation](https://developers.openai.com/codex/skills/).

## Use in Codex

```text
$go-pkg Check our go.mod, verify the pinned uuid API and examples, then implement UUID parsing with tests.
```

```text
$go-pkg Compare the public APIs of these Go libraries, check their versions and known vulnerabilities, and cite the evidence before recommending one.
```

The [skill guide](skills/go-pkg/SKILL.md) instructs agents to read local version constraints first, distinguish module paths from import paths, retrieve actual documentation before writing code, handle ambiguity and pagination, and treat returned text as untrusted reference material. It does not authorize dependency upgrades or transmitting private module names.

## Use the CLI directly

From an installed skill:

```bash
set -o pipefail
GO_PKG="$HOME/.agents/skills/go-pkg/scripts/go-pkg.sh"

bash "$GO_PKG" search 'uuid' --limit 5
bash "$GO_PKG" package github.com/google/uuid \
  --version v1.6.0 --doc md --examples --imports

# Retrieve the documentation text, not the metadata wrapper.
bash "$GO_PKG" package github.com/google/uuid \
  --version v1.6.0 --doc md | jq -r '.docs // empty'
```

For a checkout, set `GO_PKG="$PWD/skills/go-pkg/scripts/go-pkg.sh"`. For a project-scoped installation, use that project's `.agents/skills/go-pkg/scripts/go-pkg.sh`.

### Endpoint coverage

Every command maps directly to a GET operation. No HTML scraping or undocumented API endpoints are needed.

| Command | Endpoint | Research purpose |
| --- | --- | --- |
| `search` | `/search` | Discover public packages; optionally search symbols. |
| `package` | `/package/{path}` | Verify package metadata, docs, examples, imports, and licenses. |
| `module` | `/module/{path}` | Inspect module metadata, go.mod, README, and licenses. |
| `versions` | `/versions/{path}` | Inspect releases, major versions, retractions, and deprecations. |
| `packages` | `/packages/{path}` | Find the correct import path inside a module. |
| `symbols` | `/symbols/{path}` | Find exported names and their kinds before reading full docs. |
| `imported-by` | `/imported-by/{path}` | Inspect indexed usage outside the same module. |
| `vulns` | `/vulns/{path}` | Check known Go vulnerability database findings for a version. |

The additional **`spec`** helper downloads `/v1/openapi.yaml` as raw text; it is not an extra operation in the OpenAPI `paths` section.

```bash
bash "$GO_PKG" module github.com/google/uuid --version v1.6.0 --readme --licenses
bash "$GO_PKG" versions github.com/google/uuid --pseudo false --limit 10
bash "$GO_PKG" packages github.com/google/uuid --version v1.6.0 --all
bash "$GO_PKG" symbols net/http --filter 'name == "Client"' --limit 10
bash "$GO_PKG" imported-by github.com/google/uuid --limit 5
bash "$GO_PKG" vulns github.com/google/uuid --version v1.6.0 --all
bash "$GO_PKG" package --help
```

Pass versions with `--version`, not `path@version`. Options accept `--key VALUE` or `--key=VALUE`. Boolean flags accept `true`/`false`; a bare boolean flag means `true`. Unsupported options fail before any network request. Server-side `--filter` uses the API's Go-expression filter syntax, **not jq**.

### Pagination, output, and failures

By default, commands return one JSON object with the upstream response shape and pagination metadata intact. Use `--token` for manual continuation. `--all` follows the correct root or nested `nextPageToken`, combines items, retains first-page metadata, and clears the final token. It does not replace the server's `total` with an invented count.

`--all` defaults to a 20-page cap. Override it with `--max-pages N` (maximum 10000). A repeated token, cap hit, malformed page, version change, or failed later request returns an error **without printing a partial aggregate**. Page size `--limit` is separate from the page cap. There is no persistent cache.

Successful JSON is written to stdout; diagnostics and API error bodies, including ambiguity `candidates` and `fixes`, go to stderr. HTTP errors exit 22, invalid input exits 2, missing dependencies/resources exit 3, malformed responses exit 65, and pagination guards exit 75. Other curl failures preserve curl's exit status. Use `set -o pipefail` when piping into jq.

Configuration: `GO_PKG_TIMEOUT` (30 seconds per transfer), `GO_PKG_CONNECT_TIMEOUT` (10 seconds), `GO_PKG_RETRIES` (2), and `GO_PKG_BASE_URL` (`https://pkg.go.dev/v1`). Only HTTPS overrides or explicit HTTP loopback test servers are accepted. curl's retry window is capped at 60 seconds; an in-flight transfer can finish after that window. Retries use curl's transient-error behavior and `Retry-After` support. Requests are sequential, not a bulk crawler.

See [API details and source references](skills/go-pkg/references/api.md) for parameters, response fields, filters, limits, and error handling.

## Update or remove

Existing installations are intentionally never overwritten. Keep a backup **outside** any skill discovery directory, then install the reviewed update:

```bash
git pull --ff-only
mv "$HOME/.agents/skills/go-pkg" "$HOME/go-pkg-backup-$(date +%Y%m%d-%H%M%S)"
bash install.sh --user
```

To remove the user installation, remove `$HOME/.agents/skills/go-pkg` after checking that exact path. Project/custom installations are updated or removed at their corresponding destinations. Removing the checkout does not remove an installed copy.

## Project layout

```text
install.sh                         Safe local-copy installer
skills/go-pkg/
  SKILL.md                         Agent activation and endpoint research guide
  agents/openai.yaml               Codex UI and invocation metadata
  scripts/go-pkg.sh                Command parsing, validation, routing
  scripts/http.sh                  HTTP, errors, and guarded pagination
  references/endpoints.json        Reviewed routing/parameter contract
  references/api.md                Detailed response and usage reference
tests/                             Offline, HTTP, install, contract, and live checks
.github/workflows/test.yml         Linux/macOS checks; optional manual live checks
```

## Development and verification

Core tests use Bash/curl/jq. Real HTTP integration tests additionally use **Python 3.9+ from the standard library**, only as a local test server; Python is not installed with the skill and is not a runtime dependency.

```bash
bash tests/validate.sh
bash tests/test.sh
bash tests/test-install.sh
bash tests/test-contract.sh
python3 tests/test_http.py

# Explicitly makes public internet requests; not part of offline CI:
bash tests/live.sh
```

Offline tests exercise all endpoint/parameter mappings, argument and URL safety, booleans, response validation, root/nested pagination, error preservation, and installer refusal cases. Real-curl loopback tests cover wire encoding, HTTP failures, retries, and aggregation. CI targets Linux and macOS; portability targets are not a claim that every shell/OS version has already been exercised.

[Agent evaluation scenarios](tests/agent-scenarios.md) provide manual Codex activation/research checks. Script tests do not prove that a fresh Codex session followed those instructions.

### Contract provenance and limitations

The requested source is [the live OpenAPI document](https://pkg.go.dev/v1/openapi.yaml). Initial implementation reviewed the complete v1 contract in the Go team's [`golang/pkgsite` source at commit `cc0ba8e009701f9443bea53c5055718393fa6ba6`](https://github.com/golang/pkgsite/blob/cc0ba8e009701f9443bea53c5055718393fa6ba6/internal/api/openapi.yaml), because direct pkg.go.dev requests were unavailable in the implementation environment. **The deployed API was not live-verified there.** The local routing manifest is a documented subset, not a byte-for-byte vendored OpenAPI copy.

`tests/live.sh` downloads the currently served spec, compares every operation and query parameter against the manifest, and smoke-tests all eight endpoints. A mismatch fails; it never silently rewrites the implementation. For a separately downloaded JSON-formatted OpenAPI document:

```bash
bash tests/check-contract.sh /path/to/openapi.yaml
```

pkg.go.dev covers indexed **public** modules. It cannot inspect private/local replacements, prove complete adoption, resolve application-specific vulnerability reachability, or replace compilation and tests. For private or modified code, use local `go doc`, source, and tests. An empty `vulns` result is not a security guarantee; see [govulncheck](https://go.dev/doc/tutorial/govulncheck).

This project is independent of, and not endorsed by, the Go team or OpenAI. No project license has been selected in this initial scaffold; do not assume a grant of redistribution rights from the absence of a license.
