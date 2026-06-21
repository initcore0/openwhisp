#!/bin/bash
# Bundle whisper.cpp executables and their runtime dylibs into an app bundle.
# Usage:
#   scripts/bundle-whisper-runtime.sh /path/to/OpenWhisp.app [/path/to/whisper.cpp/build/bin]

set -euo pipefail

APP_DIR="${1:?App bundle path required}"
WHISPER_BIN_DIR="${2:-${WHISPER_BIN_DIR:-$HOME/whisper.cpp/build/bin}}"
WHISPER_BUILD_DIR="$(cd "$WHISPER_BIN_DIR/.." && pwd)"
WHISPER_RESOURCES="$APP_DIR/Contents/Resources/whisper"
WHISPER_LIB_DIR="$WHISPER_RESOURCES/lib"

mkdir -p "$WHISPER_RESOURCES" "$WHISPER_LIB_DIR"

copy_executable() {
    local name="$1"
    local source_path="$WHISPER_BIN_DIR/$name"
    local dest_path="$WHISPER_RESOURCES/$name"
    
    if [ ! -x "$source_path" ]; then
        echo "ERROR: $name not found or not executable at $source_path"
        echo "Set WHISPER_BIN_DIR=/path/to/whisper.cpp/build/bin and rerun."
        exit 1
    fi
    
    cp "$source_path" "$dest_path"
    chmod +x "$dest_path"
    strip_absolute_rpaths "$dest_path"
    install_name_tool -add_rpath "@executable_path/lib" "$dest_path" 2>/dev/null || true
    echo "Bundled executable: $name"
}

strip_absolute_rpaths() {
    local binary_path="$1"
    otool -l "$binary_path" |
        awk '
            /cmd LC_RPATH/ { in_rpath = 1; next }
            in_rpath && /path / { print $2; in_rpath = 0 }
        ' |
        while IFS= read -r rpath; do
            if [[ "$rpath" == /* ]]; then
                install_name_tool -delete_rpath "$rpath" "$binary_path" 2>/dev/null || true
            fi
        done
}

copy_dylib() {
    local install_name="$1"
    local file_name
    file_name="$(basename "$install_name")"
    local source_path
    source_path="$(find "$WHISPER_BUILD_DIR" -name "$file_name" -print -quit)"
    
    if [ -z "$source_path" ]; then
        echo "ERROR: dependency $file_name not found under $WHISPER_BUILD_DIR"
        exit 1
    fi
    
    local dest_path="$WHISPER_LIB_DIR/$file_name"
    cp -L "$source_path" "$dest_path"
    chmod +w "$dest_path"
    strip_absolute_rpaths "$dest_path"
    install_name_tool -id "@rpath/$file_name" "$dest_path"
    install_name_tool -add_rpath "@loader_path" "$dest_path" 2>/dev/null || true
    echo "Bundled dylib: $file_name"
}

copy_executable "whisper-cli"
copy_executable "whisper-server"

dependencies=$(
    {
        otool -L "$WHISPER_RESOURCES/whisper-cli"
        otool -L "$WHISPER_RESOURCES/whisper-server"
    } | awk '/@rpath\/.*\.dylib/ { print $1 }' | sort -u
)

while IFS= read -r dependency; do
    [ -z "$dependency" ] && continue
    copy_dylib "$dependency"
done <<< "$dependencies"

echo "Whisper runtime bundled at: $WHISPER_RESOURCES"
