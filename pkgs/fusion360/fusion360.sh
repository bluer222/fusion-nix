#!/usr/bin/env bash
# fusion360 - Nix wrapper to install and run Autodesk Fusion 360 via Wine.
# Packaging patterns inspired by https://github.com/mrshmllow/affinity-nix
# Installation logic and Wine fixes adapted from https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux
#
# This script does NOT redistribute Autodesk Fusion 360. It downloads the installer
# directly from Autodesk on first run. You must have a valid Autodesk account/license.
set -euo pipefail

VERSION="0.2.1"

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

# GUI progress state
GUI_ENABLED=0
GUI_TEMP_DIR=""
GUI_PIPE=""
GUI_PID=""

log_info() { printf '\033[0;32m[info]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# GUI Progress System (Zenity)
# -----------------------------------------------------------------------------

gui_init() {
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && -z "${FUSION360_NOGUI:-}" ]] && command -v zenity >/dev/null 2>&1; then
    GUI_ENABLED=1
    GUI_TEMP_DIR="$(mktemp -d -t fusion360-ui-XXXXXX)"
    GUI_PIPE="$GUI_TEMP_DIR/progress.pipe"
    mkfifo "$GUI_PIPE"

    zenity --progress \
      --title="Autodesk Fusion 360 Setup" \
      --text="Preparing Autodesk Fusion 360 installation..." \
      --percentage=0 \
      --auto-close \
      --no-cancel \
      --width=520 \
      --icon-name=fusion360 <"$GUI_PIPE" &
    GUI_PID=$!

    # Keep writing end open on descriptor 3
    exec 3>"$GUI_PIPE"
  fi
}

gui_step() {
  local pct="$1"
  local msg="$2"
  log_info "$msg"
  if [[ $GUI_ENABLED -eq 1 ]]; then
    if [[ -n "$pct" ]]; then
      echo "$pct" >&3 2>/dev/null || true
    fi
    if [[ -n "$msg" ]]; then
      echo "# $msg" >&3 2>/dev/null || true
    fi
  fi
}

gui_download() {
  local name="$1" dest="$2" primary_url="$3" fallback_url="${4:-}"
  local start_pct="${5:-0}" end_pct="${6:-100}"

  if [[ -s "$dest" ]]; then
    log_info "$name already downloaded, reusing $dest"
    gui_step "$end_pct" "$name ready (cached)"
    return 0
  fi

  log_info "Downloading $name..."
  gui_step "$start_pct" "Downloading $name..."

  local tmp_dest="${dest}.tmp.$$"

  download_curl_stream() {
    local target_url="$1"
    if [[ $GUI_ENABLED -eq 1 ]]; then
      # Stream curl progress bar and scale percentage within [start_pct, end_pct]
      curl -fL --retry 3 --connect-timeout 15 -# -o "$tmp_dest" "$target_url" 2>&1 \
        | tr '\r' '\n' \
        | sed -un 's/.*\ \([0-9]\{1,3\}\)\.[0-9]%.*/\1/p' \
        | while read -r p; do
            local scaled=$(( start_pct + (p * (end_pct - start_pct) / 100) ))
            echo "$scaled" >&3 2>/dev/null || true
            echo "# Downloading $name ($p%)..." >&3 2>/dev/null || true
          done
    else
      curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$tmp_dest" "$target_url"
    fi
  }

  if ! download_curl_stream "$primary_url" || [[ ! -s "$tmp_dest" ]]; then
    if [[ -n "$fallback_url" ]]; then
      log_warn "Primary download URL failed, attempting fallback URL..."
      gui_step "$start_pct" "Primary download failed, attempting fallback for $name..."
      if ! download_curl_stream "$fallback_url" || [[ ! -s "$tmp_dest" ]]; then
        rm -f "$tmp_dest"
        log_err "Failed to download $name from all sources"
        return 1
      fi
    else
      rm -f "$tmp_dest"
      log_err "Failed to download $name from $primary_url"
      return 1
    fi
  fi

  mv -f "$tmp_dest" "$dest"
  gui_step "$end_pct" "Downloaded $name successfully."
}

gui_close() {
  if [[ $GUI_ENABLED -eq 1 ]]; then
    echo "100" >&3 2>/dev/null || true
    echo "# Setup complete! Launching Autodesk Fusion 360..." >&3 2>/dev/null || true
    sleep 1
    exec 3>&- 2>/dev/null || true
    if [[ -n "$GUI_PID" ]]; then
      wait "$GUI_PID" 2>/dev/null || true
    fi
    if [[ -n "$GUI_TEMP_DIR" ]]; then
      rm -rf "$GUI_TEMP_DIR" 2>/dev/null || true
    fi
    GUI_ENABLED=0
  fi
}

gui_error() {
  local msg="$1"
  log_err "$msg"
  if [[ $GUI_ENABLED -eq 1 ]]; then
    exec 3>&- 2>/dev/null || true
    zenity --error \
      --title="Autodesk Fusion 360 Setup Error" \
      --text="$msg\n\nDetailed installation logs are located in:\n$LOGS" \
      --width=480 2>/dev/null || true
    if [[ -n "$GUI_TEMP_DIR" ]]; then
      rm -rf "$GUI_TEMP_DIR" 2>/dev/null || true
    fi
    GUI_ENABLED=0
  fi
}

# -----------------------------------------------------------------------------
# CLI Usage & Verification Helpers
# -----------------------------------------------------------------------------

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
  FUSION360_NOGUI=1     Disable graphical setup dialogs and progress bars
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

# -----------------------------------------------------------------------------
# Wine Prefix Configuration & Installation Steps
# -----------------------------------------------------------------------------

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
  log_info "Installing core runtime dependencies via winetricks (this takes a few minutes)..."
  log_info "Follow detailed logs in $LOGS/winetricks.log"
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

run_webview2_installer() {
  local installer="$1"
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

run_fusion_pass_1() {
  local installer="$1"
  log_info "Running Autodesk installer (pass 1/2 - extracting client)..."
  timeout -k 12m 10m wine "$installer" --quiet >>"$LOGS/fusion-install.log" 2>&1 || true
  wineserver -w >>"$LOGS/fusion-install.log" 2>&1 || true
}

run_fusion_pass_2() {
  local installer="$1"
  log_info "Running Autodesk installer (pass 2/2 - configuring components)..."
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
    qt_target="$(find "$PREFIX" -name 'Qt6WebEngineCore.dll' -printf "%T+ %p\n" 2>/dev/null | sort -r | head -n 1 | sed -r 's/^[^ ]+ //' || true)"
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

# -----------------------------------------------------------------------------
# Main Application Actions
# -----------------------------------------------------------------------------

do_install() {
  ensure_dirs

  # If launched from GUI without an interactive terminal, prompt before the initial ~15 min install
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && -z "${FUSION360_NOGUI:-}" ]] && ! [ -t 0 ] && command -v zenity >/dev/null 2>&1; then
    if ! zenity --question \
      --title="Autodesk Fusion 360 Setup" \
      --text="Autodesk Fusion 360 is not installed yet.\n\nWould you like to install it now?\n\nThis will download ~2 GB of dependencies and set up an isolated Wine prefix in:\n$PREFIX\n\nInstallation typically takes 5–15 minutes." \
      --ok-label="Install" \
      --cancel-label="Cancel" \
      --width=480 2>/dev/null; then
      log_info "Installation canceled by user."
      exit 0
    fi
  fi

  gui_init

  gui_step 5 "Step 1/8: Initializing Wine prefix..."
  wineboot_init

  gui_step 12 "Step 2/8: Configuring prefix sandbox mode..."
  setup_sandbox

  gui_step 20 "Step 3/8: Installing runtime libraries (.NET 4.8, VC++ 2022, fonts)..."
  install_winetricks_deps

  gui_step 48 "Step 4/8: Applying Wine compatibility registry tweaks..."
  configure_registry

  local webview_installer="$DOWNLOADS/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
  gui_download "WebView2 runtime" "$webview_installer" "$WEBVIEW2_URL" "$WEBVIEW2_BACKUP_URL" 50 60

  gui_step 60 "Step 5/8: Installing Microsoft Edge WebView2 runtime..."
  run_webview2_installer "$webview_installer"

  gui_step 66 "Step 6/8: Configuring graphics pipeline (DXVK / Vulkan)..."
  setup_graphics

  local fusion_installer="$DOWNLOADS/FusionClientInstaller.exe"
  gui_download "Autodesk Fusion installer" "$fusion_installer" "$FUSION360_INSTALLER_URL" "" 70 82

  gui_step 82 "Step 7/8: Running Autodesk installer (pass 1/2 - extracting)..."
  run_fusion_pass_1 "$fusion_installer"

  gui_step 90 "Step 7/8: Finalizing Autodesk installer (pass 2/2)..."
  run_fusion_pass_2 "$fusion_installer"

  gui_step 95 "Step 8/8: Applying SpaceMouse & system DLL compatibility fixes..."
  apply_post_install_patches

  gui_step 98 "Step 8/8: Registering Autodesk Identity Manager SSO handler..."
  register_desktop_handlers

  if is_installed; then
    local launcher
    launcher="$(find_launcher)"
    log_info "Autodesk Fusion 360 successfully installed: $launcher"
    gui_close
  else
    local err="Installation finished but Fusion360.exe was not detected in $PREFIX"
    gui_error "$err"
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

  # Display transient desktop notification if in graphical session
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && -z "${FUSION360_NOGUI:-}" ]] && command -v zenity >/dev/null 2>&1; then
    zenity --notification --text="Starting Autodesk Fusion 360..." 2>/dev/null || true
  fi

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
  gui_init
  gui_step 10 "Updating Autodesk Fusion 360..."
  local installer="$DOWNLOADS/FusionClientInstaller.exe"
  rm -f "$installer"
  gui_download "Autodesk Fusion installer" "$installer" "$FUSION360_INSTALLER_URL" "" 20 60
  gui_step 60 "Running update (pass 1/2)..."
  run_fusion_pass_1 "$installer"
  gui_step 85 "Finalizing update (pass 2/2)..."
  run_fusion_pass_2 "$installer"
  gui_step 95 "Re-applying compatibility patches..."
  apply_post_install_patches
  gui_close
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
  echo "Zenity Available: $(command -v zenity >/dev/null 2>&1 && echo "Yes" || echo "No")"

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

# -----------------------------------------------------------------------------
# Main CLI Dispatcher
# -----------------------------------------------------------------------------

main() {
  # Handle global --no-gui flag
  if [[ "${1:-}" == "--no-gui" ]]; then
    export FUSION360_NOGUI=1
    shift
  fi

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
