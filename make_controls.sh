#!/usr/bin/env bash
# Generate the FHEM updater manifest from the Git-published Perl modules.
set -euo pipefail
export LC_ALL=C
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if [[ $# -gt 1 || ( $# -eq 1 && ${1:-} != '--check' ) ]]; then
    echo 'Usage: bash make_controls.sh [--check]' >&2
    exit 2
fi

control=controls_matter.txt
tmp=$(mktemp "${control}.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT
now=$(date -u '+%Y-%m-%d_%H:%M:%S')

printf '# FHEM Controls\n' > "$tmp"
for file in FHEM/*.pm; do
    [[ -f "$file" ]] || continue

    # Git's --path filter normalizes checkout-specific CRLF transformations.
    # GitHub publishes the blob size, not the byte size of a Windows checkout.
    blob=$(git hash-object -w --path="$file" "$file")
    size=$(git cat-file -s "$blob")
    previous_date=''
    previous_blob=''
    if [[ -f "$control" ]]; then
        previous_date=$(awk -v path="$file" '$1 == "UPD" && $4 == path { print $2; exit }' "$control")
        previous_blob=$(awk -v path="$file" '$1 == "#" && $2 == "git-blob" && $4 == path { print $3; exit }' "$control")
    fi

    if [[ "$blob" == "$previous_blob" && "$previous_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        stamp=$previous_date
    else
        stamp=$now
        # FHEM compares timestamp and length. A same-size code change must
        # increase the timestamp, even if both changes occur in one second.
        if [[ "$previous_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}:[0-9]{2}$ && ! "$stamp" > "$previous_date" ]]; then
            previous_epoch=$(date -u -d "${previous_date/_/ } UTC" '+%s')
            stamp=$(date -u -d "@$((previous_epoch + 1))" '+%Y-%m-%d_%H:%M:%S')
        fi
    fi

    # Comments are ignored by FHEM's updater; the blob IDs make repeated
    # generation stable across Git checkouts and merge strategies.
    printf 'UPD %s %s %s\n# git-blob %s %s\n' "$stamp" "$size" "$file" "$blob" "$file" >> "$tmp"
done

if [[ ${1:-} == '--check' ]]; then
    if [[ -f "$control" ]] && cmp -s "$control" "$tmp"; then
        echo "$control is current"
    else
        echo "$control is stale. Run: bash make_controls.sh" >&2
        diff -u "$control" "$tmp" || true
        exit 1
    fi
else
    chmod 644 "$tmp"
    mv -- "$tmp" "$control"
    echo "Updated $control"
fi
