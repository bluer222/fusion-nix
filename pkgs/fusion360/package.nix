{ lib
, stdenvNoCC
, fetchFromGitea
, runCommand
, makeWrapper
, bash
, wineWow64Packages
, winetricks
, curl
, cabextract
, p7zip
, findutils
, coreutils
, gnugrep
, gnused
, gawk
, xdg-utils
, procps
, zenity
, gettext
, util-linux
}:
let
  wineBase = wineWow64Packages.stableFull;

  # winetricks strictly expects 'wine64' when managing 64-bit prefixes.
  # Wine 9/10/11 wow64 builds only ship 'wine', which caused winetricks to fail on all verbs.
  wine = runCommand "wine-wow64-compat" { inherit (wineBase) meta; } ''
    mkdir -p $out/bin
    for f in ${wineBase}/bin/*; do
      ln -s "$f" $out/bin/
    done
    ln -sf "${wineBase}/bin/wine" $out/bin/wine64
    for dir in include lib share; do
      if [ -d "${wineBase}/$dir" ]; then
        ln -s "${wineBase}/$dir" $out/
      fi
    done
  '';

  runtimePath = lib.makeBinPath [
    bash
    wine
    winetricks
    curl
    cabextract
    p7zip
    findutils
    coreutils
    gnugrep
    gnused
    gawk
    xdg-utils
    procps
    zenity
    gettext
    util-linux
  ];
in
stdenvNoCC.mkDerivation rec {
  pname = "fusion360";
  version = "0.3.0";

  src = fetchFromGitea {
    domain = "codeberg.org";
    owner = "Lolig4";
    repo = "Autodesk-Fusion-360-on-Linux";
    rev = "c38e9832ccacf475cb97898d202c04409c3f18f8";
    hash = "sha256-o+xblNt+Me8jYwa9cmVio5NDN7VMvK8S3RAWza674qU=";
  };

  nativeBuildInputs = [ makeWrapper ];

  postPatch = ''
    patchShebangs files/

    # 1. Substitute data directory to adhere to XDG standards
    substituteInPlace files/setup/autodesk_fusion_installer_x86-64.sh \
      files/setup/data/autodesk_fusion_launcher.sh \
      files/setup/data/adskidmgr-opener.sh \
      files/setup/data/fix-navbar-flicker.sh \
      files/setup/data/runner_update.sh \
      --replace-fail 'AUTODESK_ROOT_DIRECTORY="$HOME/.local/share/Autodesk-Unofficial"' \
                     'AUTODESK_ROOT_DIRECTORY="''${FUSION360_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/fusion360}"'

    # Also replace Autodesk-Unofficial in desktop template files
    substituteInPlace files/setup/data/.desktop/*.desktop \
      --replace-fail '$HOME/.local/share/Autodesk-Unofficial' \
                     '$HOME/.local/share/fusion360'

    # Guard spconvd call in launcher so missing/non-executable daemon doesn't abort startup
    substituteInPlace files/setup/data/autodesk_fusion_launcher.sh \
      --replace-fail '"$AUTODESK_ROOT_DIRECTORY/bin/spconvd"' \
                     '[[ -x "$AUTODESK_ROOT_DIRECTORY/bin/spconvd" ]] && "$AUTODESK_ROOT_DIRECTORY/bin/spconvd" 2>/dev/null || true'

    # 2. Stub out package manager and distro checks in installer
    sed -i \
      -e 's|check_required_packages() {|check_required_packages() { return 0; }\n_orig_check_required_packages() {|' \
      -e 's|install_required_packages() {|install_required_packages() { return 0; }\n_orig_install_required_packages() {|' \
      -e 's|check_secure_boot() {|check_secure_boot() { SECURE_BOOT=0; return 0; }\n_orig_check_secure_boot() {|' \
      -e 's|check_ram() {|check_ram() { return 0; }\n_orig_check_ram() {|' \
      -e 's|check_gpu_driver() {|check_gpu_driver() { if [[ "''${FUSION360_DXVK:-1}" == "0" ]]; then GPU_DRIVER="OpenGL"; else GPU_DRIVER="DXVK"; fi; GET_VRAM_MEGABYTES=4096; return 0; }\n_orig_check_gpu_driver() {|' \
      -e 's|check_gpu_vram() {|check_gpu_vram() { return 0; }\n_orig_check_gpu_vram() {|' \
      -e 's|check_disk_space() {|check_disk_space() { return 0; }\n_orig_check_disk_space() {|' \
      -e 's|check_and_install_wine() {|check_and_install_wine() { WINE_STATUS=1; return 0; }\n_orig_check_and_install_wine() {|' \
      -e 's|WINETRICKS="$AUTODESK_ROOT_DIRECTORY/bin/winetricks"|WINETRICKS="winetricks"|' \
      -e 's|download_file "winetricks" "$WINETRICKS_URL" "$AUTODESK_ROOT_DIRECTORY/bin"|:|' \
      -e 's|chmod +x "$AUTODESK_ROOT_DIRECTORY/bin/winetricks"|:|' \
      files/setup/autodesk_fusion_installer_x86-64.sh
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin \
      $out/share/applications \
      $out/share/icons/hicolor/scalable/apps \
      $out/share/fusion360/data/bin \
      $out/share/fusion360/data/downloads/DXVK \
      $out/share/fusion360/data/downloads/OpenGL \
      $out/share/fusion360/data/downloads/ViewportRefreshForcer \
      $out/share/fusion360/data/resources/.desktop

    # Install patched upstream installer
    install -Dm755 files/setup/autodesk_fusion_installer_x86-64.sh $out/share/fusion360/installer.sh

    # Install upstream data scripts
    cp -rf files/setup/data/autodesk_fusion_launcher.sh $out/share/fusion360/data/bin/
    cp -rf files/setup/data/adskidmgr-opener.sh $out/share/fusion360/data/bin/
    cp -rf files/setup/data/fix-navbar-flicker.sh $out/share/fusion360/data/bin/
    cp -rf files/setup/data/runner_update.sh $out/share/fusion360/data/bin/
    cp -rf files/setup/data/swap_desktop_files.sh $out/share/fusion360/data/bin/

    # Install stub spconvd executable (SpaceMouse daemon placeholder)
    cat > $out/share/fusion360/data/bin/spconvd << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x $out/share/fusion360/data/bin/*.sh $out/share/fusion360/data/bin/spconvd

    # Install driver options XMLs
    cp -rf files/setup/data/video_driver/DXVK/NMachineSpecificOptions.xml $out/share/fusion360/data/downloads/DXVK/
    cp -rf files/setup/data/video_driver/OpenGL/NMachineSpecificOptions.xml $out/share/fusion360/data/downloads/OpenGL/

    # Install ViewportRefreshForcer add-in
    cp -rf files/setup/data/ViewportRefreshForcer/* $out/share/fusion360/data/downloads/ViewportRefreshForcer/

    # Install desktop templates
    cp -rf files/setup/data/.desktop/* $out/share/fusion360/data/resources/.desktop/

    # Install SpaceMouse DLL from resources if present
    if [ -f ${./resources/siappdll.dll} ]; then
      cp ${./resources/siappdll.dll} $out/share/fusion360/data/bin/siappdll-msvc.dll
    fi

    # Inject runtime environment into standalone and sourced data scripts.
    # Note: We do NOT use wrapProgram on these because wrapProgram replaces the script
    # with an 'exec ...' wrapper, which terminates the parent shell when sourced (e.g. runner_update.sh).
    for script in $out/share/fusion360/installer.sh $out/share/fusion360/data/bin/*.sh; do
      sed -i '2i \
export PATH="${runtimePath}:$PATH"\
export WINE="${wine}/bin/wine"\
export WINE64="${wine}/bin/wine64"\
export WINELOADER="${wine}/bin/wine"\
export WINESERVER="${wine}/bin/wineserver"\
export WINEDLLPATH="${wineBase}/lib/wine"\
' "$script"
    done

    # Install wrapper entrypoint script
    install -Dm755 ${./fusion360-wrapper.sh} $out/bin/fusion360
    substituteInPlace $out/bin/fusion360 \
      --replace-fail "@SHARE_DIR@" "$out/share/fusion360"

    wrapProgram $out/bin/fusion360 \
      --prefix PATH : "${runtimePath}" \
      --set WINE "${wine}/bin/wine" \
      --set WINE64 "${wine}/bin/wine64" \
      --set WINELOADER "${wine}/bin/wine" \
      --set WINESERVER "${wine}/bin/wineserver" \
      --set WINEDLLPATH "${wineBase}/lib/wine"

    # Desktop entries and icons
    install -Dm644 ${./fusion360.desktop} $out/share/applications/fusion360.desktop
    install -Dm644 ${./adskidmgr-opener.desktop} $out/share/applications/adskidmgr-opener.desktop
    install -Dm644 ${./resources/autodesk_fusion.svg} $out/share/icons/hicolor/scalable/apps/fusion360.svg
    cp ${./adskidmgr-opener.desktop} $out/share/fusion360/adskidmgr-opener.desktop

    runHook postInstall
  '';

  meta = with lib; {
    description = "Autodesk Fusion 360 on Nix/NixOS via Wine";
    homepage = "https://github.com/bluer222/fusion-nix";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "fusion360";
    longDescription = ''
      Nix wrapper directly fetching and patching Autodesk-Fusion-360-on-Linux
      to run Autodesk Fusion 360 in an isolated Wine prefix under $XDG_DATA_HOME/fusion360.
    '';
  };
}
