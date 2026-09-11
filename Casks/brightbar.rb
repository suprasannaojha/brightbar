cask "brightbar" do
  version "1.0.2"
  # Pin after the first GitHub Release:
  #   shasum -a 256 BrightBar-<version>.zip
  #   ./scripts/update-cask.sh <version> <sha256>
  sha256 "998ad602846fbcfb773f754108caa270cd3966226e41d47222b852d7ff4564a4"

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
