#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$source_dir/make_controls.sh" "$tmp/"
mkdir "$tmp/FHEM"
printf 'aa\n' > "$tmp/FHEM/97_MATTER.pm"
printf 'abc\n' > "$tmp/FHEM/97_MATTERDevice.pm"
(cd "$tmp" && git init -q && bash make_controls.sh && bash make_controls.sh --check)
cp "$tmp/controls_matter.txt" "$tmp/initial_controls.txt"

# Regenerating unchanged modules must not change timestamps or output.
(cd "$tmp" && bash make_controls.sh && cmp -s controls_matter.txt initial_controls.txt)

# Modifying a file without changing its size must invalidate the manifest.
printf 'bb\n' > "$tmp/FHEM/97_MATTER.pm"
if (cd "$tmp" && bash make_controls.sh --check > /dev/null 2>&1); then
    echo 'A same-size code change was not detected' >&2
    exit 1
fi
(cd "$tmp" && bash make_controls.sh && bash make_controls.sh --check)
old_changed=$(awk '$1 == "UPD" && $4 == "FHEM/97_MATTER.pm" { print $2 }' "$tmp/initial_controls.txt")
new_changed=$(awk '$1 == "UPD" && $4 == "FHEM/97_MATTER.pm" { print $2 }' "$tmp/controls_matter.txt")
[[ "$new_changed" > "$old_changed" ]] || { echo 'Changed module timestamp did not advance' >&2; exit 1; }
old_unchanged=$(awk '$1 == "UPD" && $4 == "FHEM/97_MATTERDevice.pm" { print $2 }' "$tmp/initial_controls.txt")
new_unchanged=$(awk '$1 == "UPD" && $4 == "FHEM/97_MATTERDevice.pm" { print $2 }' "$tmp/controls_matter.txt")
[[ "$new_unchanged" == "$old_unchanged" ]] || { echo 'Unchanged module timestamp moved' >&2; exit 1; }

# A corrupted byte size must also fail --check, without rewriting the file.
sed -i 's/ 3 FHEM\/97_MATTER.pm/ 9 FHEM\/97_MATTER.pm/' "$tmp/controls_matter.txt"
cp "$tmp/controls_matter.txt" "$tmp/corrupt_controls.txt"
if (cd "$tmp" && bash make_controls.sh --check >/dev/null 2>&1); then
    echo 'An incorrect published byte size was not detected' >&2
    exit 1
fi
cmp -s "$tmp/controls_matter.txt" "$tmp/corrupt_controls.txt" || {
    echo '--check unexpectedly rewrote the manifest' >&2
    exit 1
}
(cd "$tmp" && bash make_controls.sh && bash make_controls.sh --check)
echo 'FHEM updater manifest generation tests passed'
