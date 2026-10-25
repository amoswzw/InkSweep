# Homebrew cask for InkSweep, published to github.com/amoswzw/homebrew-tap (Casks/inksweep.rb)
# by .github/workflows/release.yml, which fills in `version` and `sha256` on every release.
# Users install with: brew install --cask amoswzw/tap/inksweep
cask "inksweep" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/amoswzw/InkSweep/releases/download/v#{version}/InkSweep-#{version}.zip"
  name "InkSweep"
  name "墨扫"
  desc "Disk cleaner drawn in ink: every clean previewed, reversible and honest"
  homepage "https://github.com/amoswzw/InkSweep"

  depends_on macos: :sonoma

  app "InkSweep.app"

  uninstall quit: "com.amosw.inksweep"

  zap trash: [
    "~/Library/Application Support/InkSweep",
    "~/Library/LaunchAgents/com.amosw.inksweep.smartcare.plist",
    "~/Library/Preferences/com.amosw.inksweep.plist",
  ]
end
