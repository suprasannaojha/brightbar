cask "brightbar" do
  version "1.0.0"
  # Pin after the first GitHub Release:
  #   shasum -a 256 BrightBar-<version>.zip
  #   ./scripts/update-cask.sh <version> <sha256>
  sha256 "e41a79a0e7c1f699c92ca738f79f5ea35b7c43231d6e76d1d0be08e89fcfdc45"

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
