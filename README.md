### This is a completely vide-coded package for my personal use. Don't expect maitenence or updates.

# fusion-nix

Run Autodesk Fusion 360 on Nix and NixOS via Wine.

This is a Nix package and wrapper combining the installation & runtime recipe from [cryinkfly's Autodesk-Fusion-360-on-Linux](https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux) with the Nix packaging architecture of [mrshmllow/affinity-nix](https://github.com/mrshmllow/affinity-nix). The entire installer and lifecycle logic is handled automatically, with Nix providing reproducible Wine, winetricks, and supporting dependencies without requiring root or distro-specific package managers.

> [!NOTE]
> Not affiliated with Autodesk. Autodesk Fusion 360 is proprietary software. This repository provides only the Nix derivation and launcher wrapper. The Fusion installer is fetched directly from Autodesk on first run; you must have your own Autodesk account and license.

---

## How It Works

- **Prefix Management**: `fusion360` initializes an isolated Wine prefix in `$XDG_DATA_HOME/fusion360/wineprefixes/default` (defaults to `~/.local/share/fusion360`).
- **Sandbox Isolation**: Uses `winetricks sandbox` to isolate the Wine prefix from your `$HOME` directory so Windows installers do not create arbitrary folders or symlinks across user storage.
- **Runtime Dependencies**: Installs required Wine dependencies (`atmlib`, `gdiplus`, `corefonts`, `cjkfonts`, `dotnet20`, `dotnet48`, `msxml4`, `msxml6`, `vcrun2022`, `fontsmooth=rgb`, `winhttp`, and sets version to `win11`).
- **WebView2 & Authentication**: Installs a pinned Microsoft Edge WebView2 Evergreen runtime (v109, the Wine-tested build) with registry overrides for Windows 7 compatibility mode and disabled background updates.
- **Autodesk Identity Manager SSO Handler**: Ships `adskidmgr-opener.desktop` and registers the `x-scheme-handler/adskidmgr` protocol handler so browser-based SSO logins in Firefox/Chrome/Brave redirect seamlessly back into Fusion's `AdskIdentityManager.exe`.
- **Graphics Pipeline**:
  - **DXVK (Default)**: Preconfigures DirectX 11 over Vulkan while preserving Wine's builtin DirectX 9 (`*d3d9=builtin`) to ensure the 3D ViewCube and Navigation Bar function properly.
  - **OpenGL Fallback**: Set `FUSION360_DXVK=0` for older GPUs or virtual environments.
  - Automatically writes `NMachineSpecificOptions.xml` with optimal rendering flags (`VirtualDeviceDx11`, OpenGL for Qt RHI, `weave-dark-blue` theme, disabled proxy, and trusted SSL certificates).
- **Post-Install Fixes**: Automatically symlinks `DeviceSettingsProvider.dll` (preventing Autodesk CER crash dialogs) and applies the patched `siappdll.dll` for 3Dconnexion SpaceMouse support.

---

## Requirements

- **Architecture**: `x86_64-linux` with Nix (NixOS or standalone Nix with flakes enabled)
- **Disk Space**: ~10 GB free space for the Wine prefix, runtime downloads, and Autodesk Fusion
- **Autodesk Account**: A valid personal, startup, education, or commercial license
- **Graphics Driver**: Vulkan-capable GPU drivers (NVIDIA, Mesa RADV/Iris/Anv) for DXVK mode, or OpenGL drivers for fallback

---

## Quick Start

### Ad-hoc Run

```bash
nix run github:bluer222/fusion-nix
```

On first launch, `fusion360` will download dependencies and execute the Autodesk installer automatically. Once complete, subsequent runs will launch Fusion 360 directly.

### Install to User Profile

```bash
nix profile install github:bluer222/fusion-nix
fusion360
```

### NixOS Flake Configuration

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    fusion-nix.url = "github:bluer222/fusion-nix";
  };

  outputs = { self, nixpkgs, fusion-nix, ... }: {
    nixosConfigurations.my-pc = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          nixpkgs.overlays = [ fusion-nix.overlays.default ];
          environment.systemPackages = [ pkgs.fusion360 ];
        }
      ];
    };
  };
}
```

### Home Manager Configuration

```nix
{
  inputs = {
    fusion-nix.url = "github:bluer222/fusion-nix";
  };

  # In your home-manager configuration:
  home.packages = [
    inputs.fusion-nix.packages.${pkgs.system}.fusion360
  ];
}
```

---

## Command Reference

```bash
fusion360                # Launch Fusion 360 (installs automatically on first run)
fusion360 run [args...]  # Launch Fusion 360 with arguments passed to Fusion360.exe
fusion360 install        # Run the full automated prefix setup and installer
fusion360 update         # Download the latest installer and run an in-prefix update
fusion360 status         # Show prefix path, Wine version, and installation status
fusion360 uninstall      # Interactive uninstaller (deletes the data directory)
fusion360 uninstall -f   # Force uninstall without confirmation prompt

# Wine Passthroughs for Prefix Debugging & Tweaks:
fusion360 wine ...       # Run arbitrary wine commands in the Fusion prefix
fusion360 winetricks ... # Run winetricks verbs against the Fusion prefix
fusion360 winecfg        # Open winecfg for the Fusion prefix
fusion360 wineboot       # Run wineboot inside the Fusion prefix
fusion360 wineserver     # Send commands to wineserver for the Fusion prefix

# Protocol Handler (Invoked automatically by your browser during login):
fusion360 idmgr <URL>    # Handles adskidmgr:// SSO callback URLs
```

### Environment Overrides

| Variable | Description | Default |
| :--- | :--- | :--- |
| `FUSION360_DATA_DIR` | Base storage folder for prefix and logs | `$XDG_DATA_HOME/fusion360` (`~/.local/share/fusion360`) |
| `FUSION360_PREFIX` | Explicit Wine prefix destination | `$FUSION360_DATA_DIR/wineprefixes/default` |
| `FUSION360_DXVK` | Set to `0` to disable DXVK and use OpenGL fallback | `1` |
| `WINEDEBUG` | Wine debug channel filter | `-all,-d3d` |
| `FUSION360_INSTALLER_URL` | Custom override for Fusion installer binary | Autodesk official CDN |
| `FUSION360_WEBVIEW2_URL` | Custom override for Edge WebView2 installer | Pinned v109 runtime |

---

## Troubleshooting

- **Check Logs**: All installation and Wine logs are kept under `~/.local/share/fusion360/logs/`:
  - `fusion-install.log` - Autodesk installer output
  - `winetricks.log` - .NET, Visual C++, and font installation logs
  - `webview2.log` - Microsoft Edge WebView2 setup output
  - `dxvk.log` - DXVK installation and registry overrides
- **Browser Login / SSO**: If the browser does not redirect back into Fusion after logging in, verify that the protocol handler is registered:
  ```bash
  xdg-mime query default x-scheme-handler/adskidmgr
  # Should print: adskidmgr-opener.desktop
  ```
  If not registered, run `fusion360 install` or manually set it with:
  ```bash
  xdg-mime default adskidmgr-opener.desktop x-scheme-handler/adskidmgr
  ```
- **White / Blank Viewport**: Focus the Autodesk Fusion window and press `Ctrl+Alt+N`.
- **NVIDIA GPU Issues**: If you experience DXVK glitches on certain proprietary NVIDIA driver versions, try running with the OpenGL renderer:
  ```bash
  FUSION360_DXVK=0 fusion360
  ```
- **Resetting Prefix**: To wipe the prefix and start completely fresh:
  ```bash
  fusion360 uninstall --force
  fusion360 install
  ```

---

## Credits

- Installer architecture, Wine recipes, SpaceMouse DLL fix, and options configurations: [cryinkfly's Autodesk-Fusion-360-on-Linux](https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux) (MIT).
- Packaging patterns and Wine environment isolation inspired by [mrshmllow/affinity-nix](https://github.com/mrshmllow/affinity-nix).

## License

MIT License. See [LICENSE](LICENSE) for details. Autodesk Fusion 360, WebView2, and related components are proprietary software owned by their respective copyright holders.
