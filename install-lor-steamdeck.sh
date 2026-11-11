#!/usr/bin/env bash
# Legends of Runeterra installer for Steam Deck (SteamOS)
# Uses umu-launcher + GE-Proton to run the official Riot Client.
#
# Why GE-Proton9-27-LoR1 and not the latest GE-Proton:
#  - On GE-Proton 11.x, LoR.exe crashes 20-70 s after opening (Riot's
#    protection in stub.dll stops the game with a breakpoint, code 0x80000003).
#  - On the official GE-Proton 9-27 the game works, but Riot Client v142
#    (Oct 2026) doesn't open a window: Wine 9's user32 is missing functions.
#  - The project https://github.com/Maksim-Nikolaev/lor-proton combines both:
#    GE-Proton 9-27 + 5 Wine DLLs with stubs for those functions.
#    This script builds it from source (in a podman container) instead of
#    downloading third-party binaries.
#
# Usage:
#   ./install-lor-steamdeck.sh             installs (or repairs) the game
#   ./install-lor-steamdeck.sh --reset     wipes the Riot Client config (stuck login / black screen)
#   ./install-lor-steamdeck.sh --uninstall removes everything

set -euo pipefail

BASE="$HOME/.local/share/lor-deck"
PREFIX="$HOME/Games/legends-of-runeterra"
UMU_DIR="$BASE/umu"
LAUNCHER="$BASE/launch-lor.sh"
DESKTOP_FILE="$HOME/.local/share/applications/legends-of-runeterra.desktop"
INSTALLER_URL="https://bacon.secure.dyn.riotcdn.net/channels/public/x/installer/current/live.live.americas.exe"
RIOT_CLIENT="$PREFIX/drive_c/Riot Games/Riot Client/RiotClientServices.exe"

COMPAT_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
GE_TAG="GE-Proton9-27"
RUNNER_NAME="$GE_TAG-LoR1"
RUNNER="$COMPAT_DIR/$RUNNER_NAME"
LORPROTON_REPO="https://github.com/Maksim-Nikolaev/lor-proton.git"
LORPROTON_COMMIT="411f090f170b2415562c53c346b4985a2ba34ed6"   # reviewed version

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mErro: %s\033[0m\n' "$*" >&2; exit 1; }

umu_env() {
    export WINEPREFIX="$PREFIX"
    export GAMEID="umu-0"
    export STORE="none"
    export PROTONPATH="$RUNNER"
    export WINE_LARGE_ADDRESS_AWARE=1
    export DXVK_LOG_LEVEL=none
}

wineserver_bin() {
    echo "$RUNNER/files/bin/wineserver"
}

# Kills all Wine processes in this prefix.
# We don't use "umu-run wineboot -k": Proton waits for the current Wine to exit
# before running the command, so it hangs while the Riot Client is open.
kill_wine() {
    local ws
    ws=$(wineserver_bin)
    [ -x "$ws" ] && WINEPREFIX="$PREFIX" timeout 30 "$ws" -k 2>/dev/null || true
}

do_uninstall() {
    log "Removing Legends of Runeterra"
    [ -x "$UMU_DIR/umu-run" ] && kill_wine
    rm -rf "$PREFIX" "$BASE" "$DESKTOP_FILE" "$HOME/Desktop/legends-of-runeterra.desktop"
    echo "Removed. (Remember to delete the Steam shortcut, if you added it.)"
    exit 0
}

do_reset() {
    log "Clearing the Riot Client configuration (keeps the game installed)"
    [ -x "$UMU_DIR/umu-run" ] && kill_wine
    local rc="$PREFIX/drive_c/users/steamuser/AppData/Local/Riot Games/Riot Client"
    rm -rf "$rc/Config" "$rc/Data" "$rc/Logs"
    rm -f "$PREFIX/drive_c/ProgramData/Riot Games/RiotClientInstalls.json.bak"
    echo "Done. Open the game and log in again."
    exit 0
}

install_umu() {
    if [ -x "$UMU_DIR/umu-run" ]; then
        log "umu-launcher already installed"
        return
    fi
    log "Downloading umu-launcher (runs non-Steam games with Proton)"
    local url tmp
    url=$(curl -fsSL https://api.github.com/repos/Open-Wine-Components/umu-launcher/releases/latest \
          | grep -o '"browser_download_url": *"[^"]*zipapp\.tar"' | head -n1 | cut -d'"' -f4)
    [ -n "$url" ] || fail "couldn't find umu-launcher on GitHub. Check your internet connection."
    tmp=$(mktemp -d)
    curl -fL --progress-bar "$url" -o "$tmp/umu.tar"
    tar -xf "$tmp/umu.tar" -C "$tmp"
    mkdir -p "$UMU_DIR"
    cp -r "$tmp"/umu/* "$UMU_DIR/"
    chmod +x "$UMU_DIR/umu-run"
    rm -rf "$tmp"
}

install_runner() {
    if [ -f "$RUNNER/proton" ]; then
        log "$RUNNER_NAME already installed"
        return
    fi
    command -v podman >/dev/null || fail "podman is missing (it ships with SteamOS 3.5+)."
    command -v git >/dev/null    || fail "git is missing."

    local build="$BASE/build" ge="$COMPAT_DIR/$GE_TAG"
    mkdir -p "$build" "$COMPAT_DIR"

    if [ ! -f "$ge/proton" ]; then
        log "Downloading the official $GE_TAG"
        local url="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_TAG"
        curl -fL --progress-bar "$url/$GE_TAG.tar.gz" -o "$build/$GE_TAG.tar.gz"
        curl -fsSL "$url/$GE_TAG.sha512sum" -o "$build/$GE_TAG.sha512sum"
        (cd "$build" && sha512sum -c "$GE_TAG.sha512sum") || fail "the downloaded $GE_TAG is corrupted."
        tar -xzf "$build/$GE_TAG.tar.gz" -C "$COMPAT_DIR"
    fi

    log "Building $RUNNER_NAME (5 Wine DLLs; takes a few minutes)"
    local src="$build/lor-proton"
    rm -rf "$src"
    git clone -q "$LORPROTON_REPO" "$src"
    git -C "$src" checkout -q "$LORPROTON_COMMIT"

    # build.sh uses docker; SteamOS has podman. keep-id makes the created
    # files belong to the user.
    mkdir -p "$build/bin"
    cat > "$build/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then shift; exec podman run --userns=keep-id "$@"; fi
exec podman "$@"
EOF
    chmod +x "$build/bin/docker"

    # GE-Proton files ship read-only; build.sh needs to replace DLLs in the copy.
    chmod -R u+w "$ge"
    PATH="$build/bin:$PATH" "$src/build.sh" --base "$ge" \
        || fail "the build failed. See the logs in $src/build/"

    mv "$src/dist/$RUNNER_NAME" "$COMPAT_DIR/"
    [ -f "$RUNNER/proton" ] || fail "$RUNNER_NAME did not get installed."

    # Cleans up ~2 GB of build files
    podman rmi -f lor-proton-build >/dev/null 2>&1 || true
    rm -rf "$build"
}

# Older installs from this script used GE-Proton 11.x. Proton accepts switching
# the prefix to 9-27-LoR1 (tested: the game opens), but we warn the user.
check_prefix_version() {
    [ -f "$PREFIX/version" ] || return 0
    local v
    v=$(cat "$PREFIX/version")
    if [ "$v" != "$RUNNER_NAME" ]; then
        log "The prefix was created with '$v'; it will switch to $RUNNER_NAME the next time it opens"
        echo "If the Riot Client or the game don't open after this: ./install-lor-steamdeck.sh --uninstall and install again."
    fi
}

install_riot_client() {
    if [ -f "$RIOT_CLIENT" ]; then
        log "Riot Client already installed"
        return
    fi
    log "Downloading the official Riot installer"
    local exe="$BASE/lor-installer.exe"
    curl -fL --progress-bar "$INSTALLER_URL" -o "$exe"

    log "Preparing Proton (the first time takes a few minutes)"
    mkdir -p "$PREFIX"
    umu_env
    cat <<'EOF'

  >>> The Riot window is about to open.
  >>> Click INSTALL in the first and second windowand wait for Legends of Runeterra to finish downloading.
  >>> Do NOT log in to the installer. When it finishes, close the window
  >>> (and the Riot tray icon, if it appears). The script continues on its own.

EOF
    "$UMU_DIR/umu-run" "$exe" || true
    kill_wine
    [ -f "$RIOT_CLIENT" ] || fail "the Riot Client did not get installed. Run the script again."
}

write_launcher() {
    log "Creating the launcher"
    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Opens LoR and closes the Riot Client when the game exits,
# so Steam knows the game has ended.
export WINEPREFIX="$PREFIX"
export GAMEID="umu-0"
export STORE="none"
export PROTONPATH="$RUNNER"
export WINE_LARGE_ADDRESS_AWARE=1
export DXVK_LOG_LEVEL=none
UMU="$UMU_DIR/umu-run"

"\$UMU" "$RIOT_CLIENT" --launch-product=bacon --launch-patchline=live &

# Match by process name (-x), not by command line (-f),
# to avoid catching other processes that have "LoR.exe" in their text.
# Wait up to 10 min for the game to open (includes login and update time)
for _ in \$(seq 600); do
    pgrep -x 'LoR.exe' >/dev/null && break
    sleep 1
done
# Wait while the game is running
while pgrep -x 'LoR.exe' >/dev/null; do sleep 2; done

# Close the Riot Client (and the rest of Wine in this prefix)
WINEPREFIX="$PREFIX" timeout 30 "$(wineserver_bin)" -k
exit 0
EOF
    chmod +x "$LAUNCHER"

    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Legends of Runeterra
Exec=$LAUNCHER
Icon=applications-games
Categories=Game;
Terminal=false
EOF
    [ -d "$HOME/Desktop" ] && cp "$DESKTOP_FILE" "$HOME/Desktop/" && chmod +x "$HOME/Desktop/legends-of-runeterra.desktop"
}

add_to_steam() {
    log "Adding to Steam"
    # Don't duplicate the shortcut if the script is run again
    if grep -a -q -s "$LAUNCHER" "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf; then
        echo "Already in Steam."
        return
    fi
    if command -v steamos-add-to-steam >/dev/null 2>&1; then
        steamos-add-to-steam "$DESKTOP_FILE" && return
    fi
    echo "Couldn't add it automatically."
    echo "In Steam (Desktop Mode): Games > Add a Non-Steam Game > Legends of Runeterra."
}

# ---------- main ----------
case "${1:-}" in
    --uninstall) do_uninstall ;;
    --reset)     do_reset ;;
    "" )         ;;
    *)           fail "unknown option: $1" ;;
esac

command -v curl >/dev/null || fail "curl is missing."
command -v python3 >/dev/null || fail "python3 is missing (umu needs it)."
free_gb=$(df -BG --output=avail "$HOME" | tail -n1 | tr -dc '0-9')
[ "${free_gb:-0}" -ge 20 ] || fail "you need at least 20 GB free (you have ${free_gb} GB)."

mkdir -p "$BASE"
install_umu
install_runner
check_prefix_version
install_riot_client
write_launcher
add_to_steam

log "Done!"
cat <<EOF
- Go back to Game Mode and open "Legends of Runeterra" in your library (Non-Steam section).
- The first launch takes a while: the Riot Client updates itself and asks you to log in.
- Controls: the touchscreen works as a mouse. In Steam, choose the
  "Keyboard and Mouse" layout to use the right trackpad as a cursor.
- If login gets stuck or the screen stays black: ./install-lor-steamdeck.sh --reset
EOF
