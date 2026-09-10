cask "brightbar" do
  version "1.0.0"
  # Pin after the first GitHub Release:
  #   shasum -a 256 BrightBar-<version>.zip
  #   ./scripts/update-cask.sh <version> <sha256>
  sha256 :no_check

  url "https://github.com/suprasannaojha/brightbar/releases/download/v#{version}/BrightBar-#{version}.zip"
  name "BrightBar"
  desc "Control external monitor brightness from the menu bar"
  homepage "https://github.com/suprasannaojha/brightbar"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "BrightBar.app"

  zap trash: [
    "~/Library/Preferences/com.brightbar.app.plist",
  ]
end
