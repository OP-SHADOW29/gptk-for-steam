# Third-party software

The MIT license in this repository covers only the GPTK for Steam code. The app download
(`GPTK for Steam.app`) also bundles the software below, unchanged, each under its own
license. The license files travel inside the app at the paths shown.

## Apple Game Porting Toolkit 3.0 and 4.0 beta 3 (evaluation environment)

`Contents/Resources/gptk/` — D3DMetal, `libd3dshared` and the DirectX graphics libraries from
Apple's *Evaluation environment for Windows games* (`redist/lib`).

Apple's license allows distributing these redistributables for non-commercial purposes only,
with Apple's notices kept. GPTK for Steam is free and non-commercial. Apple's License,
Acknowledgements and Read Me are in `Contents/Resources/gptk/LICENSES/<version>/`.
Copyright © Apple Inc.

## Wine 11 with GPTK support

`Contents/Resources/wine-11-gptk/` — a build of Wine 11 (`wine-11.0-gbdfedbca358`) taken from
the GameHub app for macOS. It carries Apple's Game Porting Toolkit hooks and Valve's Proton
Steam code.

Wine is free software by the Wine project authors under the GNU Lesser General Public License,
version 2.1 or later (`LICENSE-LGPL-2.1.txt` and `NOTICE.txt` in that folder).
Wine source code: <https://gitlab.winehq.org/wine/wine>.
This build includes changes by others (Valve's Proton, Apple's GPTK support and GameHub's own).
The source code for those changes was not published with the build and is not included.

## Wine 7.7 for GPTK 3 (downloaded, not bundled)

Downloaded during setup from Gcenx's Game Porting Toolkit build
(<https://github.com/Gcenx/game-porting-toolkit>), LGPL-2.1-or-later.

## NotProton

`Contents/Resources/notproton/` — NotProton's Steam Play enabler (`notproton.dylib`), its support
files, and the Steam bridge (`lsteamclient`, `steam.exe`), unchanged from NotProton's own build.

- NotProton: GNU GPL version 3 (`LICENSE-GPL-3.0.txt`).
- lsteamclient: Valve's Steamworks SDK license (`LICENSE.lsteamclient.txt`).
- steam.exe: a port of Valve's steam_helper, BSD-3-Clause (`LICENSE.steam-shim.txt`).
- See `NOTICE-NotProton.txt` and `README.txt` in that folder.

Source code: <https://github.com/NotProtonNot/NotProton>

## Valve's Windows Steam files (not bundled)

`steamclient.dll`, `steamclient64.dll`, `tier0_s64.dll` and `vstdlib_s64.dll` are not included.
GPTK for Steam takes them from the player's own Steam installation or downloads them from
Valve's servers, checked against fixed hashes.
