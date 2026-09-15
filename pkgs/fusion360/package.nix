{ lib
, stdenvNoCC
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
}:
let
  wine = wineWow64Packages.stableFull;
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
  ];
in
stdenvNoCC.mkDerivation rec {
  pname = "fusion360";
  version = "0.2.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin \
      $out/share/applications \
      $out/share/icons/hicolor/scalable/apps \
      $out/share/fusion360/resources

    # Copy bundled resources
    cp -r $src/resources/* $out/share/fusion360/resources/

    # Install launcher script with substituted resources path
    install -Dm755 $src/fusion360.sh $out/bin/fusion360
    substituteInPlace $out/bin/fusion360 \
      --replace-fail "@RESOURCES_DIR@" "$out/share/fusion360/resources"

    # Wrap launcher with runtime dependencies and explicit Wine environment
    wrapProgram $out/bin/fusion360 \
      --prefix PATH : "${runtimePath}" \
      --set WINE "${wine}/bin/wine" \
      --set WINELOADER "${wine}/bin/wine" \
      --set WINESERVER "${wine}/bin/wineserver" \
      --set WINEDLLPATH "${wine}/lib/wine"

    # Install desktop entries
    install -Dm644 $src/fusion360.desktop $out/share/applications/fusion360.desktop
    install -Dm644 $src/adskidmgr-opener.desktop $out/share/applications/adskidmgr-opener.desktop

    # Install scalable icon
    install -Dm644 $src/resources/autodesk_fusion.svg $out/share/icons/hicolor/scalable/apps/fusion360.svg

    runHook postInstall
  '';

  meta = with lib; {
    description = "Autodesk Fusion 360 on Nix/NixOS via Wine";
    homepage = "https://github.com/bluer222/fusion-nix";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "fusion360";
    longDescription = ''
      Nix wrapper that manages and runs Autodesk Fusion 360 in an isolated Wine prefix
      under $XDG_DATA_HOME/fusion360. Fusion itself is downloaded directly from Autodesk
      on first run and requires your own Autodesk account and license.
      Installer logic is adapted from cryinkfly's Autodesk-Fusion-360-on-Linux
      and packaging architecture inspired by mrshmllow/affinity-nix.
    '';
  };
}
