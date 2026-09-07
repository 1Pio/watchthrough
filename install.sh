#!/bin/sh
set -eu

fail() {
    printf 'watchthrough install: %s\n' "$1" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BINARY="$SCRIPT_DIR/dist/macos-arm64/watchthrough"
CHECKSUM="$SCRIPT_DIR/dist/macos-arm64/watchthrough.sha256"
SKILL_SOURCE="$SCRIPT_DIR/skill"

[ "$(uname -s)" = "Darwin" ] || fail "version 1 supports macOS only"
[ "$(uname -m)" = "arm64" ] || fail "version 1 requires Apple Silicon"

case "${HOME:-}" in
    /*) ;;
    *) fail "HOME must be an absolute path" ;;
esac

[ -x "$BINARY" ] || fail "committed executable is missing: $BINARY"
[ -f "$CHECKSUM" ] || fail "committed checksum is missing: $CHECKSUM"
[ -f "$SKILL_SOURCE/SKILL.md" ] || fail "agent skill is missing: $SKILL_SOURCE/SKILL.md"

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
    legacy_source=${4:-}

    if [ -L "$target_path" ]; then
        current=$(/usr/bin/readlink "$target_path")
        [ "$current" = "$source_path" ] || [ "$current" = "$legacy_source" ] ||
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

link_skill() {
    if [ -L "$SKILL_LINK" ]; then
        current=$(/usr/bin/readlink "$SKILL_LINK")
        [ "$current" = "$SKILL_SOURCE" ] && return
        [ "$current" = "$SCRIPT_DIR" ] ||
            fail "skill link already points elsewhere: $SKILL_LINK"

        temporary_link="$SKILL_DIR/.watchthrough-link-$$"
        /bin/ln -s "$SKILL_SOURCE" "$temporary_link"
        # Both paths share a directory. -h replaces the owned symlink itself
        # instead of following its directory target.
        /bin/mv -fh "$temporary_link" "$SKILL_LINK"
        return
    fi
    /bin/ln -s "$SKILL_SOURCE" "$SKILL_LINK"
}

preflight_link "$BINARY" "$BIN_LINK" "command"
preflight_link "$SKILL_SOURCE" "$SKILL_LINK" "skill" "$SCRIPT_DIR"

/bin/mkdir -p "$BIN_DIR" "$SKILL_DIR"
link_once "$BINARY" "$BIN_LINK"
link_skill

"$BIN_LINK" status

case ":${PATH:-}:" in
    *":$BIN_DIR:"*) ;;
    *) printf 'Add %s to PATH to invoke watchthrough by name.\n' "$BIN_DIR" ;;
esac

printf 'Installed watchthrough command: %s\n' "$BIN_LINK"
printf 'Installed watchthrough skill:   %s\n' "$SKILL_LINK"
