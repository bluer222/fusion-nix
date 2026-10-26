#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
wrapper="$test_dir/fusion360"
share="$test_dir/share"
mkdir -p "$share/data/bin" "$test_dir/bin"
sed "s|@SHARE_DIR@|$share|g" "$repo/pkgs/fusion360/fusion360-wrapper.sh" > "$wrapper"
chmod +x "$wrapper"
printf 'patched DLL' > "$share/data/bin/siappdll-msvc.dll"

cat > "$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *"$FUSION360_INSTALLER_URL"* ]]
printf 'download attempted\n' >> "$FUSION360_TEST_CALLS"
case "${FUSION360_TEST_FAILURE:-}" in
  download) exit 22 ;;
  empty) exit 0 ;;
esac
printf 'fresh installer' > "${!#}"
EOF
cat > "$test_dir/bin/prefix-wine" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$WINEPREFIX" == "$FUSION360_TEST_PREFIX" ]]
[[ "$WINESERVER" == /test/prefix-wineserver ]]
[[ "$#" == 4 && "$2" == --process && "$3" == update && "$4" == --quiet ]]
[[ "$(cat "$1")" == 'fresh installer' ]]
printf 'updater started\n' >> "$FUSION360_TEST_CALLS"
echo 'installer log output'
if [[ "${FUSION360_TEST_FAILURE:-}" == installer ]]; then
  exit 42
fi
new="$WINEPREFIX/drive_c/Program Files/Autodesk/webdeploy/production/new version"
mkdir -p "$new/ADPCER"
touch "$new/Fusion360.exe" "$new/ADPCER/DeviceSettingsProvider.dll"
if [[ ! -e "$new/siappdll.dll" ]]; then
  printf 'original DLL' > "$new/siappdll.dll"
fi
EOF
chmod +x "$test_dir/bin/"*

data="$test_dir/Fusion data"
pfx="$data/wineprefixes/fusion-7"
old="$pfx/drive_c/Program Files/Autodesk/webdeploy/production/old version"
mkdir -p "$data/logs/fusion-7" "$old" "$data/downloads"
printf '%s\n' fusion-7 > "$data/logs/active_fusion.log"
config="$data/logs/fusion-7/prefix.config"
printf '%s\n' DXVK "$pfx" --wine "$test_dir/bin/prefix-wine" /test/prefix-wineserver > "$config"
cp "$config" "$test_dir/original-config"
touch -t 202001010000 "$old/Fusion360.exe"
printf 'existing user data' > "$pfx/user-settings"
printf 'stale installer' > "$data/downloads/FusionClientInstaller.exe"
export PATH="$test_dir/bin:$PATH" FUSION360_DATA_DIR="$data"
export FUSION360_TEST_PREFIX="$pfx" FUSION360_TEST_CALLS="$test_dir/calls"
export FUSION360_INSTALLER_URL=https://example.invalid/fusion.exe

# Updating preserves the active installation and applies fixes to the new version.
"$wrapper" update
new="$(dirname "$old")/new version"
[[ "$(cat "$pfx/user-settings")" == 'existing user data' ]]
[[ "$(cat "$data/logs/active_fusion.log")" == fusion-7 ]]
cmp "$config" "$test_dir/original-config"
[[ "$(find "$data/wineprefixes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]]
[[ "$(readlink "$new/siappdll.dll")" == "$data/bin/siappdll-msvc.dll" ]]
[[ "$(cat "$new/siappdll.dll.bak")" == 'original DLL' ]]
[[ "$(readlink "$new/DeviceSettingsProvider.dll")" == "$new/ADPCER/DeviceSettingsProvider.dll" ]]
grep -q 'installer log output' "$data/logs/fusion-update.log"
[[ "$(cat "$data/downloads/FusionClientInstaller.exe")" == 'stale installer' ]]
[[ -z "$(find "$data" -name 'FusionUpdate.*')" ]]
"$wrapper" update
[[ "$(cat "$new/siappdll.dll.bak")" == 'original DLL' ]]

# Failed downloads and installers report failure without claiming success or patching DLLs.
for failure in download empty installer; do
  rm "$new/DeviceSettingsProvider.dll"
  : > "$test_dir/calls"
  status=0
  FUSION360_TEST_FAILURE="$failure" "$wrapper" update > "$test_dir/output" 2>&1 || status=$?
  [[ "$status" -ne 0 ]]
  if [[ "$failure" == installer ]]; then
    [[ "$status" -eq 42 ]]
    grep -q 'installer log output' "$data/logs/fusion-update.log"
  else
    if grep -q 'updater started' "$test_dir/calls"; then
      echo 'Updater ran after a failed download' >&2
      exit 1
    fi
  fi
  if grep -q 'update completed' "$test_dir/output"; then
    echo 'Failed update reported success' >&2
    exit 1
  fi
  [[ ! -e "$new/DeviceSettingsProvider.dll" ]]
  [[ -z "$(find "$data" -name 'FusionUpdate.*')" ]]
  ln -s "$new/ADPCER/DeviceSettingsProvider.dll" "$new/DeviceSettingsProvider.dll"
done

# An absent installation must not trigger a download or initialize a Wine prefix.
: > "$test_dir/calls"
if FUSION360_DATA_DIR="$test_dir/empty" "$wrapper" update > "$test_dir/output" 2>&1; then
  echo 'Update unexpectedly accepted an empty installation' >&2
  exit 1
fi
grep -q 'No Fusion installation' "$test_dir/output"
[[ ! -s "$test_dir/calls" ]]
[[ -z "$(find "$test_dir/empty/wineprefixes" -mindepth 1 -print -quit)" ]]
