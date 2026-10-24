# Template for Casks/tsubame.rb in the Homebrew tap. The release workflow fills in
# __VERSION__ and __SHA256__ for each stable release and pushes the result; edit
# this file, not the tap's copy.
cask "tsubame" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/kakushindev/tsubame/releases/download/v#{version}/Tsubame-#{version}.dmg"
  name "Tsubame"
  desc "Native Kubernetes management app"
  homepage "https://github.com/kakushindev/tsubame"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Tsubame.app"

  # Credentials live in the login Keychain, which Homebrew does not touch.
  zap trash: [
    "~/Library/Caches/dev.kakushin.tsubame",
    "~/Library/HTTPStorages/dev.kakushin.tsubame",
    "~/Library/Preferences/dev.kakushin.tsubame.plist",
    "~/Library/Saved Application State/dev.kakushin.tsubame.savedState",
  ]
end
