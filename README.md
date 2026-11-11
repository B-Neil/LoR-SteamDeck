# Legends of Runeterra on Steam Deck

Installs the official Riot Client and Legends of Runeterra inside Proton (via
[umu-launcher](https://github.com/Open-Wine-Components/umu-launcher)) and adds the game to Steam.
No `sudo`. You need about 20 GB free and an internet connection.


## Install

1. Switch to **Desktop Mode** (Steam button > Power > Switch to Desktop).
2. Put this folder in `~/Downloads`, open **Konsole** and run:
   ```bash
   cd ~/Downloads/lor-steamdeck
   chmod +x install-lor-steamdeck.sh
   ./install-lor-steamdeck.sh
   ```
3. The first run builds a patched Proton. This takes a few minutes.
4. When the Riot window opens: click **Install**, wait until it finishes, after the first window closes it will open the client, click install again and close the windowwhen the download is finished.
5. Go back to Game Mode. The game is in the library under **Non-Steam**.

The script builds [lor-proton](https://github.com/Maksim-Nikolaev/lor-proton) from source (GE-Proton 9-27 plus
5 Wine DLLs that add the functions the Riot Client needs), using the `podman` that ships with SteamOS.
It uses the official GE-Proton 9-27 release (checksum verified) and a pinned, reviewed commit of lor-proton.

Tested on 2026-11-11 with SteamOS on a Steam Deck. Riot can change the client at any time.
