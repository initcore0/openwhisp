# frozen_string_literal: true

cask "openwhisp" do
  version "1.0.13,168"
  sha256 "8cb61a20a8397ff02c33c9e64668668551408a276dfb1182a4b0bf3f17195a61"

  # The release tag is v<shortVersion>+<build> (e.g. v1.0.0+155). Homebrew stores
  # that as version "1.0.0,155" (version,revision); the URL rebuilds the tag from
  # both halves. bump-cask.sh keeps these three lines (version/sha256) in sync on
  # every tagged release.
  url "https://github.com/initcore0/openwhisp/releases/download/v#{version.csv.first}+#{version.csv.second}/OpenWhisp.dmg",
      verified: "github.com/initcore0/openwhisp/"
  name "OpenWhisp"
  desc "Local-first realtime dictation with an agent bridge and MCP server"
  homepage "https://openwhisp.app/"

  # OpenWhisp updates itself in-app via Sparkle (EdDSA-signed appcast), so Homebrew
  # should not try to manage upgrades or flag the cask as outdated.
  auto_updates true
  depends_on macos: :sequoia # LSMinimumSystemVersion is 15.0

  app "OpenWhisp.app"

  uninstall quit: "com.openwhisp.app"

  # Support/cache/preference paths the app actually writes under ~/Library.
  # Verified in-source (grep for applicationSupportDirectory / Library/Caches /
  # the com.openwhisp.app bundle id):
  #   Application Support/OpenWhisp   — profiles, modes, meetings, history,
  #                                     vocabulary, file-queue, correction
  #                                     proposals, whisperkit-models/
  #   Caches/com.openwhisp.app        — staged audio + refine-debug.log
  #   Preferences/com.openwhisp.app.plist — UserDefaults.standard
  # NOTE: Parakeet models live under Application Support/FluidAudio/Models, a
  # directory shared with the FluidAudio library and NOT owned by this bundle, so
  # it is deliberately left out of zap.
  zap trash: [
    "~/Library/Application Support/OpenWhisp",
    "~/Library/Caches/com.openwhisp.app",
    "~/Library/HTTPStorages/com.openwhisp.app",
    "~/Library/Preferences/com.openwhisp.app.plist",
    "~/Library/Saved Application State/com.openwhisp.app.savedState",
  ]
end
