#!/bin/bash
# Shared helper: resolve the in-repo plugin sources and the swiftc define that
# compiles them in (docs/PLUGINS.md).
#
# In-repo plugins are ON BY DEFAULT, like WhisperKit / Parakeet / Sparkle; opt out
# with PLUGINS=0 for a lean build.
#
# COMPILED IN != ENABLED. Every plugin is DISABLED at runtime until the user turns it
# on per-plugin in Settings → Plugins (`PluginEnablement` defaults to the empty set).
# This flag decides what code EXISTS; the pane decides what RUNS.
#
# The pure plugin core (PluginManifest / PluginDiscovery / PluginEnablement /
# PluginRegistry and the meme rules) lives under OpenWhisp/Services and is ALWAYS
# compiled and always covered by `swift test`. PLUGINS=0 drops only the plugins' own
# AppKit/SwiftUI surfaces under plugins/, which is what makes it a safe lean-build
# escape hatch rather than a second product configuration.
#
# Sourced by BOTH build.sh and build-dmg.sh — the whole point of the helper — so a
# released DMG carries plugins exactly the way a local build does. The two compile
# paths drifting is the failure this file exists to prevent.
#
# Sets:
#   PLUGIN_DEFINE_ARGS  — ( -DOPENWHISP_PLUGINS ) or empty
#   PLUGIN_SOURCES      — array of .swift paths under plugins/ (empty when off)
#
# Requires PROJECT_DIR to be set by the caller.

resolve_plugin_source_args() {
    PLUGIN_DEFINE_ARGS=()
    PLUGIN_SOURCES=()

    if [ "${PLUGINS:-1}" = "0" ]; then
        echo "Plugins: disabled (lean build, PLUGINS=0)" >&2
        return 0
    fi

    while IFS= read -r f; do
        PLUGIN_SOURCES+=("$f")
    done < <(find "$PROJECT_DIR/plugins" -name "*.swift")

    PLUGIN_DEFINE_ARGS=( -DOPENWHISP_PLUGINS )
    echo "Plugins: ENABLED (${#PLUGIN_SOURCES[@]} source file(s) from plugins/)" >&2
}
