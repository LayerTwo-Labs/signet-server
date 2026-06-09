#!/usr/bin/env bash
#
# Populate the BIP300 hash_id_1 / hash_id_2 fields of the sidechains/*.json
# proposal requests from each sidechain's most recent GitHub release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECHAIN_DIR="$REPO_ROOT/sidechains"

# slot -> github owner/repo of the canonical node software.
declare -A REPOS=(
    [2]="LayerTwo-Labs/plain-bitnames"
    [4]="LayerTwo-Labs/plain-bitassets"
    [9]="LayerTwo-Labs/thunder-rust"
    [13]="LayerTwo-Labs/truthcoin-dc"
    [98]="iwakura-rein/thunder-orchard"
    [99]="LayerTwo-Labs/photon"
    [255]="LayerTwo-Labs/coinshift-rs"
)

command -v gh >/dev/null || { echo "❌ gh (GitHub CLI) is required" >&2; exit 1; }

shopt -s nullglob
files=("$SIDECHAIN_DIR"/*.json)
shopt -u nullglob
[ ${#files[@]} -gt 0 ] || { echo "❌ no request files in $SIDECHAIN_DIR" >&2; exit 1; }

for f in "${files[@]}"; do
    slot="$(jq -r '.sidechain_id' "$f")"
    repo="${REPOS[$slot]:-}"
    if [ -z "$repo" ]; then
        echo "❌ slot $slot ($(basename "$f")): no repo mapping" >&2
        exit 1
    fi

    # Most recent published release (excludes drafts and pre-releases).
    tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
    if [ -z "$tag" ]; then
        echo "❌ slot $slot ($repo): no published release" >&2
        exit 1
    fi

    # hash_id_2: the 20-byte (40 hex) commit the release tag resolves to.
    commit="$(gh api "repos/$repo/commits/$tag" --jq '.sha' 2>/dev/null || true)"
    if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
        echo "❌ slot $slot ($repo@$tag): could not resolve commit" >&2
        exit 1
    fi

    # hash_id_1: sha256 of the release's source tarball.
    tarball="$(mktemp)"
    if ! curl -fsSL "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" -o "$tarball"; then
        echo "❌ slot $slot ($repo@$tag): tarball download failed" >&2
        rm -f "$tarball"
        exit 1
    fi
    h1="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    rm -f "$tarball"

    tmp="$(mktemp)"
    jq --arg h1 "$h1" --arg h2 "$commit" \
        '.declaration.v0.hash_id_1.hex = $h1 | .declaration.v0.hash_id_2.hex = $h2' \
        "$f" > "$tmp" && mv "$tmp" "$f"

    echo "✅ slot $slot  $repo  $tag"
    echo "     hash_id_1 $h1"
    echo "     hash_id_2 $commit"
done
