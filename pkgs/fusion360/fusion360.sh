#!/usr/bin/env bash
# fusion360 - Nix wrapper to install and run Autodesk Fusion 360 via Wine.
# Packaging patterns inspired by https://github.com/mrshmllow/affinity-nix
# Installation logic and Wine fixes adapted from https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux
#
# This script does NOT redistribute Autodesk Fusion 360. It downloads the installer
# directly from Autodesk on first run. You must have a valid Autodesk account/license.
set -euo pipefail

VERSION="0.2.0"

# Upstream download endpoints
FUSION360_INSTALLER_URL="${FUSION360_INSTALLER_URL:-https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe}"
WEBVIEW2_URL="${FUSION360_WEBVIEW2_URL:-https://archive.org/download/microsoft-edge-web-view-2-runtime-installer-v109.0.1518.78/MicrosoftEdgeWebView2RuntimeInstallerX64.exe}"
WEBVIEW2_BACKUP_URL="https://github.com/aedancullen/webview2-evergreen-standalone-installer-archive/releases/download/109.0.1518.78/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"

# Storage locations
DATA_DIR="${FUSION360_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fusion360}"
PREFIX="${FUSION360_PREFIX:-$DATA_DIR/wineprefixes/default}"
DOWNLOADS="$DATA_DIR/downloads"
LOGS="$DATA_DIR/logs"

# Bundled resource directory (substituted during nix build)
RESOURCES_DIR="${FUSION360_RESOURCES_DIR:-@RESOURCES_DIR@}"
if [[ "$RESOURCES_DIR" == "@"*"@" ]]; then
  # Fallback when running un-substituted script directly from repository tree
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RESOURCES_DIR="$SCRIPT_DIR/resources"
fi

# Wine runtime environment
export WINEARCH=win64
export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all,-d3d}"
export WINETRICKS_UPDATE_CHECK=0
export WINETRICKS_LATEST_VERSION_CHECK=disabled
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"

log_info() { printf '\033[0;32m[info]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<EOF
fusion360 $VERSION - Run Autodesk Fusion 360 on Nix/NixOS via Wine

Usage:
  fusion360 [COMMAND] [ARGS...]

Commands:
  (no args)             Launch Fusion 360 (installs automatically on first run)
  run [ARGS]...         Launch Fusion 360, passing ARGS to Fusion360.exe
  install               Run full prefix initialization and install Fusion 360
  update                Download latest installer and run in-prefix update
  uninstall [--force]   Remove Fusion 360 wine prefix and data directory
  status                Show prefix configuration, launcher path, and status
  idmgr <URL>           Autodesk Identity Manager SSO callback handler (adskidmgr://)
  wine ARGS...          Run wine within the Fusion 360 prefix
  winetricks ARGS...    Run winetricks within the Fusion 360 prefix
  winecfg [ARGS]...     Run winecfg within the Fusion 360 prefix
  wineboot [ARGS]...    Run wineboot within the Fusion 360 prefix
  wineserver [ARGS]...  Run wineserver commands within the Fusion 360 prefix
  help, -h, --help      Show this help text
  version, -V, --version Show version

Environment Variables:
  FUSION360_DATA_DIR    Base data directory (default: \$XDG_DATA_HOME/fusion360)
  FUSION360_PREFIX      Wine prefix path (default: \$DATA_DIR/wineprefixes/default)
  FUSION360_DXVK=0      Disable DXVK and use OpenGL fallback
  WINEDEBUG             Wine debug channels (default: -all,-d3d)
  FUSION360_INSTALLER_URL Override Autodesk Fusion installer URL
  FUSION360_WEBVIEW2_URL  Override Microsoft Edge WebView2 installer URL

Prefix Path:  $PREFIX
Logs Path:    $LOGS
EOF
}

ensure_dirs() {
  mkdir -p "$PREFIX" "$DOWNLOADS" "$LOGS"
}

download_file() {
  local name="$1" dest="$2" primary_url="$3" secondary_url="${4:-}"
  if [[ -s "$dest" ]]; then
    log_info "$name already downloaded, reusing $dest"
    return 0
  fi
  log_info "Downloading $name ..."
  if ! curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$dest" "$primary_url"; then
    if [[ -n "$secondary_url" ]]; then
      log_warn "Primary download URL failed, attempting fallback URL..."
      curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$dest" "$secondary_url"
    else
      log_err "Failed to download $name from $primary_url"
      return 1
    fi
  fi
}

find_launcher() {
  [[ -d "$PREFIX" ]] || return 0
  find "$PREFIX" -iname "Fusion360.exe" -printf "%T+ %p\n" 2>/dev/null \
    | sort -r | head -n 1 | sed -r 's/^[^ ]+ //' || true
}

find_idmgr() {
  [[ -d "$PREFIX" ]] || return 0
  find "$PREFIX" -iname "AdskIdentityManager.exe" -printf "%T+ %p\n" 2>/dev/null \
    | sort -r | head -n 1 | sed -r 's/^[^ ]+ //' || true
}

is_installed() {
  [[ -n "$(find_launcher)" ]]
}

wineboot_init() {
  log_info "Initializing Wine prefix at $PREFIX"
  wine wineboot --init >>"$LOGS/wineboot.log" 2>&1
  wineserver -w >>"$LOGS/wineboot.log" 2>&1 || true
}

setup_sandbox() {
  log_info "Configuring Wine prefix sandbox mode"
  winetricks -q sandbox >>"$LOGS/sandbox.log" 2>&1 || true
  # Link downloads folder inside prefix for installer visibility
  local wine_user_downloads="$PREFIX/drive_c/users/$USER/Downloads"
  rm -rf "$wine_user_downloads"
  mkdir -p "$(dirname "$wine_user_downloads")"
  ln -sf "$DOWNLOADS" "$wine_user_downloads"
  wineserver -w >>"$LOGS/sandbox.log" 2>&1 || true
}

install_winetricks_deps() {
  log_info "Installing core runtime dependencies via winetricks (this may take several minutes)..."
  log_info "Logs are written to $LOGS/winetricks.log"
  # Verbs required for Fusion 360: .NET 4.8, Visual C++ 2022, XML parsing, core and CJK fonts
  winetricks -q atmlib gdiplus corefonts cjkfonts dotnet20 dotnet48 \
    msxml4 msxml6 vcrun2022 fontsmooth=rgb winhttp win10 \
    >>"$LOGS/winetricks.log" 2>&1
  # Upstream note: repeat cjkfonts if needed and lock version to Windows 11
  winetricks -q cjkfonts >>"$LOGS/winetricks.log" 2>&1 || true
  winetricks -q win11 >>"$LOGS/winetricks.log" 2>&1
  wineserver -w >>"$LOGS/winetricks.log" 2>&1 || true
}

configure_registry() {
  log_info "Applying Wine registry overrides and compatibility keys"
  # DllOverrides to disable telemetry crashes and force native/builtin compatibility
  wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "adpclientservice.exe" /t REG_SZ /d native /f >>"$LOGS/registry.log" 2>&1 || true
  wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "AdCefWebBrowser.exe" /t REG_SZ /d builtin /f >>"$LOGS/registry.log" 2>&1 || true
  wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "msvcp140" /t REG_SZ /d native /f >>"$LOGS/registry.log" 2>&1 || true
  wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "mfc140u" /t REG_SZ /d native /f >>"$LOGS/registry.log" 2>&1 || true
  wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "bcp47langs" /t REG_SZ /d "" /f >>"$LOGS/registry.log" 2>&1 || true

  # X11 driver window manager hints
  wine reg add "HKCU\\Software\\Wine\\X11 Driver" /v "Managed" /t REG_SZ /d "Y" /f >>"$LOGS/registry.log" 2>&1 || true
  wine reg add "HKCU\\Software\\Wine\\X11 Driver" /v "Decorated" /t REG_SZ /d "Y" /f >>"$LOGS/registry.log" 2>&1 || true

  wineserver -w >>"$LOGS/registry.log" 2>&1 || true
}

install_webview2() {
  local installer="$DOWNLOADS/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
  download_file "Microsoft Edge WebView2 runtime" "$installer" "$WEBVIEW2_URL" "$WEBVIEW2_BACKUP_URL"
  log_info "Installing Microsoft Edge WebView2 runtime (pinned v109 build)"
  # WebView2 installer works best when wine reports win7 during setup
  wine winecfg -v win7 >>"$LOGS/webview2.log" 2>&1 || true
  wine "$installer" /silent /install >>"$LOGS/webview2.log" 2>&1 || true
  wine winecfg -v win11 >>"$LOGS/webview2.log" 2>&1 || true

  local regfile
  regfile="$(mktemp)"
  cat >"$regfile" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\edgeupdate]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\edgeupdatem]
"Start"=dword:00000004

[HKEY_CURRENT_USER\Software\Wine\AppDefaults]

[HKEY_CURRENT_USER\Software\Wine\AppDefaults\msedgewebview2.exe]
"Version"="win7"
REG
  wine regedit /S "$regfile" >>"$LOGS/webview2.log" 2>&1 || true
  rm -f "$regfile"
  wine taskkill /f /im MicrosoftEdgeUpdate.exe >>"$LOGS/webview2.log" 2>&1 || true
  wineserver -w >>"$LOGS/webview2.log" 2>&1 || true
}

setup_graphics() {
  local use_dxvk="${FUSION360_DXVK:-1}"
  local options_file

  if [[ "$use_dxvk" == "1" ]]; then
    log_info "Configuring graphics driver: DXVK (DirectX 11 over Vulkan)"
    winetricks -q dxvk >>"$LOGS/dxvk.log" 2>&1
    if [[ -f "$RESOURCES_DIR/DXVK.reg" ]]; then
      wine regedit /S "$RESOURCES_DIR/DXVK.reg" >>"$LOGS/dxvk.log" 2>&1 || true
    fi
    options_file="$RESOURCES_DIR/NMachineSpecificOptions-dxvk.xml"
  else
    log_info "Configuring graphics driver: OpenGL fallback"
    options_file="$RESOURCES_DIR/NMachineSpecificOptions-opengl.xml"
  fi

  # Deploy NMachineSpecificOptions.xml to standard Fusion Neutron Platform settings locations
  local target_dirs=(
    "$PREFIX/drive_c/users/$USER/AppData/Roaming/Autodesk/Neutron Platform/Options"
    "$PREFIX/drive_c/users/$USER/AppData/Local/Autodesk/Neutron Platform/Options"
    "$PREFIX/drive_c/users/$USER/Application Data/Autodesk/Neutron Platform/Options"
  )

  for dir in "${target_dirs[@]}"; do
    mkdir -p "$dir"
    if [[ -f "$options_file" ]]; then
      cp -f "$options_file" "$dir/NMachineSpecificOptions.xml"
      log_info "Deployed graphics options to $dir"
    fi
  done

  wineserver -w >>"$LOGS/dxvk.log" 2>&1 || true
}

install_fusion_installer() {
  local installer="$DOWNLOADS/FusionClientInstaller.exe"
  download_file "Autodesk Fusion installer" "$installer" "$FUSION360_INSTALLER_URL"
  log_info "Executing Autodesk installer (quiet mode, multi-pass)..."
  log_info "Follow progress in $LOGS/fusion-install.log"

  # Autodesk's installer requires a first extraction pass and a second configuration pass
  timeout -k 12m 10m wine "$installer" --quiet >>"$LOGS/fusion-install.log" 2>&1 || true
  sleep 3
  timeout -k 6m 4m wine "$installer" --quiet >>"$LOGS/fusion-install.log" 2>&1 || true
  wineserver -w >>"$LOGS/fusion-install.log" 2>&1 || true
}

apply_post_install_patches() {
  log_info "Applying post-installation patches..."

  # 1. DeviceSettingsProvider.dll link fix
  local production_dir="$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production"
  if [[ -d "$production_dir" ]]; then
    find "$production_dir" -path "*/ADPCER/DeviceSettingsProvider.dll" 2>/dev/null | while read -r dll_path; do
      local expected
      expected="$(dirname "$(dirname "$dll_path")")/DeviceSettingsProvider.dll"
      if [[ ! -f "$expected" ]]; then
        ln -sf "$dll_path" "$expected"
        log_info "Linked DeviceSettingsProvider.dll to $expected"
      fi
    done
  fi

  # 2. Patched siappdll.dll for 3Dconnexion SpaceMouse
  if [[ -f "$RESOURCES_DIR/siappdll.dll" ]]; then
    local qt_target
    qt_target="$(find "$PREFIX" -name 'Qt6WebEngineCore.dll' -printf "%T+ %p\n" 2>/dev/null | sort -r | head -n 1 | sed -r 's/^[^ ]+ //')"
    if [[ -n "$qt_target" ]]; then
      local target_dir
      target_dir="$(dirname "$qt_target")"
      if [[ -f "$target_dir/siappdll.dll" && ! -f "$target_dir/siappdll.dll.bak" ]]; then
        cp -f "$target_dir/siappdll.dll" "$target_dir/siappdll.dll.bak"
      fi
      cp -f "$RESOURCES_DIR/siappdll.dll" "$target_dir/siappdll.dll"
      log_info "Installed SpaceMouse siappdll.dll to $target_dir"
    fi
  fi
}

register_desktop_handlers() {
  # Register the adskidmgr-opener desktop entry for the user if xdg-mime exists
  if command -v xdg-mime >/dev/null 2>&1; then
    local user_apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$user_apps"
    if [[ -f "$RESOURCES_DIR/../applications/adskidmgr-opener.desktop" ]]; then
      cp -f "$RESOURCES_DIR/../applications/adskidmgr-opener.desktop" "$user_apps/" 2>/dev/null || true
    fi
    xdg-mime default adskidmgr-opener.desktop x-scheme-handler/adskidmgr 2>/dev/null || true
    log_info "Registered x-scheme-handler/adskidmgr protocol handler"
  fi
}

do_install() {
  ensure_dirs
  wineboot_init
  setup_sandbox
  install_winetricks_deps
  configure_registry
  install_webview2
  setup_graphics
  install_fusion_installer
  apply_post_install_patches
  register_desktop_handlers

  if is_installed; then
    local launcher
    launcher="$(find_launcher)"
    log_info "Autodesk Fusion 360 successfully installed!"
    log_info "Launcher: $launcher"
  else
    log_warn "Installation finished but Fusion360.exe was not detected in $PREFIX"
    log_warn "Check $LOGS/fusion-install.log for diagnostic information."
    return 1
  fi
}

do_launch() {
  local launcher
  launcher="$(find_launcher)"
  if [[ -z "$launcher" ]]; then
    log_info "Fusion 360 is not installed yet. Running first-time installation..."
    do_install
    launcher="$(find_launcher)"
  fi

  register_desktop_handlers
  log_info "Launching Autodesk Fusion 360..."
  log_info "Executable: $launcher"

  FUSION_IDSDK=false \
  DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}" \
  wine "$launcher" "$@" &

  local pid=$!
  wait "$pid" || true
  wineserver -k || true
}

do_idmgr() {
  local url="${1:-}"
  if [[ -z "$url" ]]; then
    log_err "Missing URL argument for idmgr handler"
    return 1
  fi

  local idmgr
  idmgr="$(find_idmgr)"
  if [[ -z "$idmgr" ]]; then
    log_err "AdskIdentityManager.exe not found in $PREFIX"
    return 1
  fi

  log_info "Authenticating with Autodesk Identity Manager..."
  wine "$idmgr" "$url"
}

do_update() {
  ensure_dirs
  log_info "Updating Autodesk Fusion 360..."
  local installer="$DOWNLOADS/FusionClientInstaller.exe"
  rm -f "$installer"
  install_fusion_installer
  apply_post_install_patches
  log_info "Update complete."
}

do_uninstall() {
  local force=0
  if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    force=1
  fi

  if [[ $force -eq 0 ]]; then
    log_warn "This will permanently remove the Fusion 360 data directory:"
    log_warn "  $DATA_DIR"
    read -r -p "Are you sure you want to delete this directory? [y/N] " answer
    case "$answer" in
      [Yy]*) ;;
      *) log_info "Aborted."; return 0 ;;
    esac
  fi

  wineserver -k || true
  rm -rf "$DATA_DIR"
  log_info "Successfully removed $DATA_DIR"
}

do_status() {
  echo "Autodesk Fusion 360 Nix Package Status"
  echo "--------------------------------------"
  echo "Version:         $VERSION"
  echo "Data Directory:  $DATA_DIR"
  echo "Wine Prefix:     $PREFIX"
  echo "Logs Directory:  $LOGS"
  echo "Resources:       $RESOURCES_DIR"
  echo "Wine Version:    $(wine --version 2>/dev/null || echo "not found")"
  echo "DXVK Enabled:    ${FUSION360_DXVK:-1}"

  local launcher idmgr
  launcher="$(find_launcher)"
  idmgr="$(find_idmgr)"

  if [[ -n "$launcher" ]]; then
    echo "Installed:       Yes"
    echo "Launcher Path:   $launcher"
  else
    echo "Installed:       No"
  fi

  if [[ -n "$idmgr" ]]; then
    echo "Identity Mgr:    $idmgr"
  else
    echo "Identity Mgr:    Not detected"
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    ensure_dirs
    if is_installed; then
      do_launch
    else
      do_install && do_launch
    fi
    return
  fi

  case "$1" in
    -h|--help|help)
      usage ;;
    -V|--version|version)
      echo "fusion360 $VERSION" ;;
    run)
      shift; ensure_dirs; do_launch "$@" ;;
    install)
      do_install ;;
    update)
      do_update ;;
    uninstall)
      shift; do_uninstall "$@" ;;
    status)
      do_status ;;
    idmgr)
      shift; do_idmgr "$@" ;;
    wine)
      shift; ensure_dirs; exec wine "$@" ;;
    winetricks)
      shift; ensure_dirs; exec winetricks "$@" ;;
    winecfg)
      shift; ensure_dirs; exec wine winecfg "$@" ;;
    wineboot)
      shift; ensure_dirs; exec wine wineboot "$@" ;;
    wineserver)
      shift; ensure_dirs; exec wineserver "$@" ;;
    *)
      # Fallback: pass arguments through to launch Fusion 360
      ensure_dirs; do_launch "$@" ;;
  esac
}

main "$@"
