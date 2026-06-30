#!/bin/bash
# Bundle the llama.cpp llama-server executable and its runtime dylibs into an
# app bundle, under Contents/Resources/llama/ with its OWN lib/ directory.
#
# IMPORTANT: llama gets its own isolated dylib set — it must NOT share the
# whisper Resources/whisper/lib. whisper.cpp and llama.cpp pin different ggml
# revisions, and ggml is not ABI-versioned across projects: two builds can
# produce identically-named dylibs (e.g. libggml-base.dylib) with different
# symbols. Each server resolves its dylibs via @executable_path/lib, so keeping
# the trees separate is the structural safeguard against an ABI collision.
#
# Usage:
#   scripts/bundle-llama-runtime.sh /path/to/OpenWhisp.app [/path/to/llama.cpp/build/bin]

set -euo pipefail

APP_DIR="${1:?App bundle path required}"
LLAMA_BIN_DIR="${2:-${LLAMA_BIN_DIR:-$HOME/llama.cpp/build/bin}}"
LLAMA_BUILD_DIR="$(cd "$LLAMA_BIN_DIR/.." && pwd)"
LLAMA_RESOURCES="$APP_DIR/Contents/Resources/llama"
LLAMA_LIB_DIR="$LLAMA_RESOURCES/lib"

mkdir -p "$LLAMA_RESOURCES" "$LLAMA_LIB_DIR"

copy_executable() {
    local name="$1"
    local source_path="$LLAMA_BIN_DIR/$name"
    local dest_path="$LLAMA_RESOURCES/$name"

    if [ ! -x "$source_path" ]; then
        echo "ERROR: $name not found or not executable at $source_path"
        echo "Set LLAMA_BIN_DIR=/path/to/llama.cpp/build/bin and rerun."
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
    source_path="$(find "$LLAMA_BUILD_DIR" -name "$file_name" -print -quit)"

    if [ -z "$source_path" ]; then
        echo "ERROR: dependency $file_name not found under $LLAMA_BUILD_DIR"
        exit 1
    fi

    local dest_path="$LLAMA_LIB_DIR/$file_name"
    cp -L "$source_path" "$dest_path"
    chmod +w "$dest_path"
    strip_absolute_rpaths "$dest_path"
    install_name_tool -id "@rpath/$file_name" "$dest_path"
    install_name_tool -add_rpath "@loader_path" "$dest_path" 2>/dev/null || true
    echo "Bundled dylib: $file_name"
}

copy_executable "llama-server"

# Guard: fail loudly on any dependency we cannot bundle, instead of silently
# dropping it (the @rpath filter below would otherwise ignore a stray absolute
# dep like a Homebrew libcurl, producing a binary that dyld-fails on users).
while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
        @rpath/*|/usr/lib/*|/System/*) ;;
        *)
            echo "ERROR: un-bundleable dependency in llama-server: $dep"
            echo "Rebuild llama.cpp with the deps statically linked or as @rpath."
            exit 1
            ;;
    esac
done < <(otool -L "$LLAMA_RESOURCES/llama-server" | tail -n +2 | awk '{print $1}')

dependencies=$(
    otool -L "$LLAMA_RESOURCES/llama-server" | awk '/@rpath\/.*\.dylib/ { print $1 }' | sort -u
)

while IFS= read -r dependency; do
    [ -z "$dependency" ] && continue
    copy_dylib "$dependency"
done <<< "$dependencies"

# Transitive dylib deps: ggml dylibs depend on each other (libggml-metal needs
# libggml-base, etc.). Resolve any @rpath deps of the dylibs we just copied.
for _pass in 1 2 3; do
    missing=""
    for lib in "$LLAMA_LIB_DIR"/*.dylib; do
        [ -e "$lib" ] || continue
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            fn="$(basename "$dep")"
            if [ ! -e "$LLAMA_LIB_DIR/$fn" ]; then
                missing="$missing $dep"
            fi
        done < <(otool -L "$lib" | awk '/@rpath\/.*\.dylib/ { print $1 }')
    done
    [ -z "$missing" ] && break
    for dep in $missing; do
        copy_dylib "$dep"
    done
done

echo "llama runtime bundled at: $LLAMA_RESOURCES"
