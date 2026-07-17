#!/bin/sh
set -eu

fail() {
    printf 'watchthrough install: %s\n' "$1" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BINARY="$SCRIPT_DIR/dist/macos-arm64/watchthrough"
CHECKSUM="$SCRIPT_DIR/dist/macos-arm64/watchthrough.sha256"

[ "$(uname -s)" = "Darwin" ] || fail "version 1 supports macOS only"
[ "$(uname -m)" = "arm64" ] || fail "version 1 requires Apple Silicon"

case "${HOME:-}" in
    /*) ;;
    *) fail "HOME must be an absolute path" ;;
esac

[ -x "$BINARY" ] || fail "committed executable is missing: $BINARY"
[ -f "$CHECKSUM" ] || fail "committed checksum is missing: $CHECKSUM"

(
    cd "$SCRIPT_DIR/dist/macos-arm64"
    /usr/bin/shasum -a 256 -c watchthrough.sha256
) || fail "binary checksum verification failed"

/usr/bin/codesign --verify --strict "$BINARY" ||
    fail "binary signature verification failed"

command -v ffmpeg >/dev/null 2>&1 ||
    fail "ffmpeg is required on PATH"
command -v ffprobe >/dev/null 2>&1 ||
    fail "ffprobe is required on PATH"

BIN_DIR="$HOME/.local/bin"
SKILL_DIR="$HOME/.agents/skills"
BIN_LINK="$BIN_DIR/watchthrough"
SKILL_LINK="$SKILL_DIR/watchthrough"

preflight_link() {
    source_path=$1
    target_path=$2
    label=$3

    if [ -L "$target_path" ]; then
        current=$(/usr/bin/readlink "$target_path")
        [ "$current" = "$source_path" ] ||
            fail "$label link already points elsewhere: $target_path"
        return
    fi
    [ ! -e "$target_path" ] ||
        fail "$label path already exists and is not this installation: $target_path"
}

link_once() {
    source_path=$1
    target_path=$2

    [ -L "$target_path" ] && return
    /bin/ln -s "$source_path" "$target_path"
}

preflight_link "$BINARY" "$BIN_LINK" "command"
preflight_link "$SCRIPT_DIR" "$SKILL_LINK" "skill"

/bin/mkdir -p "$BIN_DIR" "$SKILL_DIR"
link_once "$BINARY" "$BIN_LINK"
link_once "$SCRIPT_DIR" "$SKILL_LINK"

"$BIN_LINK" status

case ":${PATH:-}:" in
    *":$BIN_DIR:"*) ;;
    *) printf 'Add %s to PATH to invoke watchthrough by name.\n' "$BIN_DIR" ;;
esac

printf 'Installed watchthrough command: %s\n' "$BIN_LINK"
printf 'Installed watchthrough skill:   %s\n' "$SKILL_LINK"
