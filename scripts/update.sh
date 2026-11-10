#!/usr/bin/env bash
#
# Regenerate sources.json from Slack's latest release of slackapi/slack-cli.
#
# Five things are pinned, and each is derived rather than typed:
#
#   version     the tag of the latest GitHub release, less its "v"
#   rev         the commit that tag points at, so a moved tag cannot
#               change what an existing pin builds
#   hash        the NAR hash of the source at that commit
#   vendorHash  the hash of the Go modules buildGoModule vendors for it
#   go          the Go minor version upstream's go.mod asks for
#
# vendorHash cannot be read off anything upstream publishes; the only way to
# know it is to have Nix vendor the modules and say what it got. So the
# script writes a placeholder, builds the package's goModules derivation,
# and takes the hash from the mismatch Nix reports. That is the standard
# trick, and the reason this needs a working nix with flakes.
#
set -euo pipefail

readonly OWNER="slackapi"
readonly REPO="slack-cli"
readonly API="https://api.github.com/repos/$OWNER/$REPO"

# The hash Nix reports a mismatch against. Any valid SRI string that cannot
# be the real one will do.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SOURCES_JSON="$ROOT/sources.json"

log() { printf '\033[0;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in curl jq nix; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]} (try: nix develop)"
}

# The GitHub API allows 60 unauthenticated requests an hour per address,
# which a shared CI runner can exhaust; use a token when there is one.
fetch() {
  local auth=()
  [ -z "${GITHUB_TOKEN:-}" ] || auth=(--header "Authorization: Bearer $GITHUB_TOKEN")
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --max-time 60 \
    "${auth[@]}" "$1"
}

# The commit a tag names. Annotated tags point at a tag object, which points
# at the commit; lightweight tags point at the commit directly.
resolve_tag() {
  local tag="$1" ref type sha
  ref="$(fetch "$API/git/ref/tags/$tag")"
  type="$(jq -r .object.type <<<"$ref")"
  sha="$(jq -r .object.sha <<<"$ref")"
  if [ "$type" = "tag" ]; then
    sha="$(fetch "$API/git/tags/$sha" | jq -r .object.sha)"
  fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve $tag to a commit"
  printf '%s' "$sha"
}

write_sources() {
  jq -n \
    --arg version "$1" --arg rev "$2" --arg hash "$3" \
    --arg vendorHash "$4" --arg go "$5" \
    '{version: $version, rev: $rev, hash: $hash, vendorHash: $vendorHash, go: $go}' \
    >"$SOURCES_JSON"
}

main() {
  local check_only=false force=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --force) force=true; shift ;;
      --help)
        cat <<'USAGE'
Usage: scripts/update.sh [--check] [--force]

Rewrites sources.json from the latest release of slackapi/slack-cli.

  --check   Report whether an update is available and exit non-zero if one
            is, without writing anything.
  --force   Rewrite sources.json even when the pinned version is already the
            newest one, so that its contents can be compared against
            upstream.
USAGE
        exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  require_tools

  # /releases/latest skips drafts and pre-releases, which is what we want:
  # only what Slack itself calls the current release.
  local tag version
  tag="$(fetch "$API/releases/latest" | jq -r .tag_name)"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected latest release tag: $tag"
  version="${tag#v}"

  local current_version
  current_version="$(jq -r '.version' "$SOURCES_JSON" 2>/dev/null || echo "none")"
  log "current: $current_version, latest: $version"

  if [ "$current_version" = "$version" ] && [ "$force" = false ]; then
    log "already up to date"
    exit 0
  fi

  if [ "$check_only" = true ]; then
    log "update available: $current_version -> $version"
    exit 1
  fi

  local rev
  rev="$(resolve_tag "$tag")"
  log "$tag is $rev"

  local hash
  hash="$(nix flake prefetch --json "github:$OWNER/$REPO/$rev" | jq -r .hash)"
  log "source $hash"

  # "go 1.27.3" -> "1.27". The patch release does not pick an attribute in
  # nixpkgs, only the minor does; a go.mod that wants a newer patch than
  # nixpkgs has fails the build, which is where it should fail.
  local go
  go="$(fetch "https://raw.githubusercontent.com/$OWNER/$REPO/$rev/go.mod" |
    awk '$1 == "go" { split($2, v, "."); print v[1] "." v[2]; exit }')"
  [[ "$go" =~ ^[0-9]+\.[0-9]+$ ]] || die "could not read the Go version from go.mod"
  log "go $go"

  # Put the old file back if anything below fails, rather than leave the
  # placeholder behind for the next build to trip over.
  local backup
  backup="$(mktemp)"
  cp "$SOURCES_JSON" "$backup"
  # Expanded now, not at trap time: $backup is a local that is out of scope
  # by the time the EXIT trap runs.
  # shellcheck disable=SC2064
  trap "cp '$backup' '$SOURCES_JSON'; rm -f '$backup'" EXIT

  write_sources "$version" "$rev" "$hash" "$FAKE_HASH" "$go"

  local output vendor_hash
  output="$(nix build --no-link "$ROOT#slack-cli.goModules" 2>&1 || true)"
  vendor_hash="$(awk '$1 == "got:" { print $2; exit }' <<<"$output")"
  if [[ "$vendor_hash" != sha256-* ]]; then
    printf '%s\n' "$output" >&2
    die "could not determine vendorHash"
  fi
  log "vendor $vendor_hash"

  write_sources "$version" "$rev" "$hash" "$vendor_hash" "$go"
  cp "$SOURCES_JSON" "$backup"
  log "wrote $SOURCES_JSON at $version"
}

main "$@"
