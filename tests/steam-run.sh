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
set -euo pipefail
if [[ -s "$FUSION360_TEST_CALLS" ]]; then
  echo "fusion360 recursively entered steam-run" >&2
  exit 1
fi
printf '%s\n' "$@" > "$FUSION360_TEST_CALLS"
# NixOS steam-run does not set this variable.
unset STEAM_RUNTIME
exec "$@"
EOF
chmod +x "$test_dir/steam-run"

env -u STEAM_RUNTIME -u FUSION360_IN_FHS \
  PATH="$test_dir:$PATH" FUSION360_TEST_CALLS="$test_dir/calls" \
  "$wrapper" --help > "$test_dir/help"

[[ "$(cat "$test_dir/calls")" == "$wrapper"$'\n''--help' ]]
grep -q '^Usage: fusion360 ' "$test_dir/help"
