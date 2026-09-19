#!/usr/bin/env bash
# fusion360-wrapper - Nix entrypoint wrapping upstream Autodesk-Fusion-360-on-Linux scripts
set -euo pipefail

DATA_DIR="${FUSION360_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fusion360}"
export FUSION360_DATA_DIR="$DATA_DIR"
export AUTODESK_ROOT_DIRECTORY="$DATA_DIR"

SHARE_DIR="@SHARE_DIR@"

ensure_structure() {
  mkdir -p "$DATA_DIR/bin" \
           "$DATA_DIR/downloads/DXVK" \
           "$DATA_DIR/downloads/OpenGL" \
           "$DATA_DIR/downloads/ViewportRefreshForcer" \
           "$DATA_DIR/logs" \
           "$DATA_DIR/resources/.desktop" \
           "$DATA_DIR/wineprefixes"

  # Populate bundled upstream data & scripts from Nix store if missing or updated
  if [[ -d "$SHARE_DIR/data" ]]; then
    cp -rf "$SHARE_DIR/data/bin/"* "$DATA_DIR/bin/" 2>/dev/null || true
    chmod +x "$DATA_DIR/bin/"*.sh 2>/dev/null || true
    cp -rf "$SHARE_DIR/data/downloads/"* "$DATA_DIR/downloads/" 2>/dev/null || true
    cp -rf "$SHARE_DIR/data/resources/"* "$DATA_DIR/resources/" 2>/dev/null || true
    # Touch files so upstream download_file treats them as fresh (<7 days) and skips curl
    find "$DATA_DIR/downloads" "$DATA_DIR/bin" "$DATA_DIR/resources" -type f -exec touch {} + 2>/dev/null || true
  fi

  # Compatibility migration for existing fusion-nix prefixes (e.g. wineprefixes/default)
  if [[ ! -f "$DATA_DIR/logs/active_fusion.log" ]]; then
    local pfx=""
    if [[ -d "$DATA_DIR/wineprefixes/default" ]]; then
      pfx="default"
    elif [[ -d "$DATA_DIR/wineprefixes" ]]; then
      local first_pfx
      first_pfx="$(find "$DATA_DIR/wineprefixes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1)"
      if [[ -n "$first_pfx" ]]; then
        pfx="$(basename "$first_pfx")"
      fi
    fi

    if [[ -n "$pfx" ]]; then
      mkdir -p "$DATA_DIR/logs/$pfx"
      echo "$pfx" > "$DATA_DIR/logs/active_fusion.log"
      echo "$pfx" > "$DATA_DIR/logs/active_adskidmgr-opener.log"
      if [[ ! -f "$DATA_DIR/logs/$pfx/prefix.config" ]]; then
        cat > "$DATA_DIR/logs/$pfx/prefix.config" <<EOF
DXVK
$DATA_DIR/wineprefixes/$pfx
--wine
wine
wineserver
EOF
      fi
    fi
  fi
}

get_active_prefix() {
  local active_log="$DATA_DIR/logs/active_fusion.log"
  if [[ -f "$active_log" ]]; then
    local pfx_name
    pfx_name="$(cat "$active_log" 2>/dev/null || true)"
    local config="$DATA_DIR/logs/$pfx_name/prefix.config"
    if [[ -f "$config" ]]; then
      awk 'NR == 2' "$config"
      return 0
    fi
  fi
  if [[ -d "$DATA_DIR/wineprefixes/default" ]]; then
    echo "$DATA_DIR/wineprefixes/default"
    return 0
  fi
  return 1
}

find_launcher() {
  local pfx
  pfx="$(get_active_prefix 2>/dev/null || true)"
  if [[ -n "$pfx" && -d "$pfx" ]]; then
    find "$pfx" -iname "Fusion360.exe" -printf "%T+ %p\n" 2>/dev/null \
      | sort -r | head -n 1 | sed -r 's/^[^ ]+ //' || true
  fi
}

is_installed() {
  [[ -n "$(find_launcher)" ]]
}

register_desktop_handlers() {
  if command -v xdg-mime >/dev/null 2>&1; then
    local user_apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$user_apps"
    if [[ -f "$SHARE_DIR/adskidmgr-opener.desktop" ]]; then
      cp -f "$SHARE_DIR/adskidmgr-opener.desktop" "$user_apps/" 2>/dev/null || true
    fi
    xdg-mime default adskidmgr-opener.desktop x-scheme-handler/adskidmgr 2>/dev/null || true
  fi
}

do_install() {
  ensure_structure
  register_desktop_handlers
  "$SHARE_DIR/installer.sh" --install fusion --wine --safe --refresh-forcer "$@"
}

do_launch() {
  ensure_structure
  register_desktop_handlers
  if ! is_installed; then
    echo "[info] Fusion 360 is not installed yet. Starting installation..."
    do_install
  fi

  exec "$DATA_DIR/bin/autodesk_fusion_launcher.sh" fusion "$@"
}

do_status() {
  ensure_structure
  echo "Autodesk Fusion 360 (Upstream Script Wrapper)"
  echo "----------------------------------------------"
  echo "Data Directory:  $DATA_DIR"
  local active_pfx
  active_pfx="$(get_active_prefix || echo "not detected")"
  echo "Active Prefix:   $active_pfx"
  local launcher
  launcher="$(find_launcher)"
  if [[ -n "$launcher" ]]; then
    echo "Installed:       Yes"
    echo "Launcher Path:   $launcher"
  else
    echo "Installed:       No"
  fi
  echo "Wine Version:    $(wine --version 2>/dev/null || echo "not found")"
  if [[ -f "$DATA_DIR/logs/active_fusion.log" ]]; then
    local pfx_name
    pfx_name="$(cat "$DATA_DIR/logs/active_fusion.log")"
    echo "Active Profile:  $pfx_name"
    if [[ -f "$DATA_DIR/logs/$pfx_name/prefix.config" ]]; then
      echo "--- prefix.config ---"
      cat "$DATA_DIR/logs/$pfx_name/prefix.config"
      echo "---------------------"
    fi
  fi
}

do_uninstall() {
  local force=0
  if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    force=1
  fi

  if [[ $force -eq 0 ]]; then
    echo "WARNING: This will delete the Fusion 360 data directory and prefixes:"
    echo "  $DATA_DIR"
    read -r -p "Are you sure you want to delete this directory? [y/N] " ans
    case "$ans" in
      [Yy]*) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  wineserver -k 2>/dev/null || true
  rm -rf "$DATA_DIR"
  echo "Successfully removed $DATA_DIR"
}

main() {
  if [[ $# -eq 0 ]]; then
    do_launch
    return
  fi

  case "$1" in
    -h|--help|help)
      echo "fusion360 - Run Autodesk Fusion 360 on Nix via Wine"
      echo ""
      echo "Usage: fusion360 [COMMAND] [ARGS...]"
      echo ""
      echo "Commands:"
      echo "  (no args)             Launch Fusion 360 (installs on first run)"
      echo "  install               Run upstream installer directly"
      echo "  run [ARGS...]         Launch Fusion 360 passing extra arguments"
      echo "  status                Display installation and prefix status"
      echo "  fix-navbar            Run upstream navigation bar flicker fix"
      echo "  idmgr <URL>           Autodesk Identity Manager SSO callback handler"
      echo "  wine ARGS...          Run wine inside the active prefix"
      echo "  winetricks ARGS...    Run winetricks inside the active prefix"
      echo "  winecfg               Open winecfg for the active prefix"
      echo "  wineserver ARGS...    Send commands to wineserver for active prefix"
      echo "  uninstall [--force]   Remove Fusion 360 prefix and data directory"
      ;;
    install)
      shift; do_install "$@" ;;
    run)
      shift; do_launch "$@" ;;
    status)
      do_status ;;
    fix-navbar)
      ensure_structure
      exec "$DATA_DIR/bin/fix-navbar-flicker.sh" ;;
    idmgr)
      shift; ensure_structure
      exec "$DATA_DIR/bin/adskidmgr-opener.sh" "$@" ;;
    wine)
      shift; ensure_structure
      local pfx; pfx="$(get_active_prefix)"
      WINEPREFIX="$pfx" exec wine "$@" ;;
    winetricks)
      shift; ensure_structure
      local pfx; pfx="$(get_active_prefix)"
      WINEPREFIX="$pfx" exec winetricks "$@" ;;
    winecfg)
      shift; ensure_structure
      local pfx; pfx="$(get_active_prefix)"
      WINEPREFIX="$pfx" exec wine winecfg "$@" ;;
    wineserver)
      shift; ensure_structure
      local pfx; pfx="$(get_active_prefix)"
      WINEPREFIX="$pfx" exec wineserver "$@" ;;
    uninstall)
      shift; do_uninstall "$@" ;;
    *)
      do_launch "$@" ;;
  esac
}

main "$@"
