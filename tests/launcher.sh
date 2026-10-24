#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
wrapper="$test_dir/fusion360"
cp "$repo/pkgs/fusion360/fusion360-wrapper.sh" "$wrapper"
chmod +x "$wrapper"

cat > "$test_dir/steam-run" <<'EOF'
#!/usr/bin/env bash
echo 'The Nixpkgs Wine launcher must not enter steam-run' >&2
exit 1
EOF
cat > "$test_dir/wine" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$WINEPREFIX" "$@" > "$FUSION360_TEST_WINE"
EOF
chmod +x "$test_dir/steam-run" "$test_dir/wine"

data="$test_dir/Fusion data"
mkdir -p "$data/logs/default" "$data/wineprefixes/default"
printf '%s\n' default > "$data/logs/active_fusion.log"
config="$data/logs/default/prefix.config"
printf '%s\n' DXVK "$data/wineprefixes/default" --fusion-wine \
  "$data/fusion-wine-build/bin/wine" "$data/fusion-wine-build/bin/wineserver" \
  'preserve extra settings' > "$config"
cp "$config" "$test_dir/original"
printf '%s\n' DXVK "$data/wineprefixes/default" --wine wine wineserver \
  'preserve extra settings' > "$test_dir/expected"

export PATH="$test_dir:$PATH" FUSION360_DATA_DIR="$data" FUSION360_TEST_WINE="$test_dir/wine-call"
unset STEAM_RUNTIME
"$wrapper" --help | grep -q '^Usage: fusion360 '
"$wrapper" wine --version
[[ "$(cat "$test_dir/wine-call")" == "$data/wineprefixes/default"$'\n''--version' ]]
cmp "$config" "$test_dir/expected"
cmp "$config.fusion-wine.bak" "$test_dir/original"

"$wrapper" wine --version
cmp "$config" "$test_dir/expected"
cmp "$config.fusion-wine.bak" "$test_dir/original"
