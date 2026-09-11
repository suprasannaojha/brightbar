cask "brightbar" do
  version "1.0.1"
  # Pin after the first GitHub Release:
  #   shasum -a 256 BrightBar-<version>.zip
  #   ./scripts/update-cask.sh <version> <sha256>
  sha256 "9f27cbef91db05b1ff5878561ce762255409ff3afcdbb6e5ef0c47103a2b8f2e"

  url "https://github.com/suprasannaojha/brightbar/releases/download/v#{version}/BrightBar-#{version}.zip"
  name "BrightBar"
  desc "Control external monitor brightness from the menu bar"
  homepage "https://github.com/suprasannaojha/brightbar"

  # Symbol form means "this version or later" in current Homebrew.
  depends_on macos: :ventura
  depends_on arch: :arm64

  app "BrightBar.app"

  uninstall quit: "com.brightbar.app"

  zap trash: "~/Library/Preferences/com.brightbar.app.plist"
end
