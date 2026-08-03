cask "lumisync" do
  version "0.1.0-dev"
  sha256 :no_check

  url "https://github.com/Dee-0503/LumiSync/releases/download/v#{version}/LumiSync-#{version}.zip"
  name "LumiSync"
  desc "Synchronize MacBook keyboard backlight with display brightness"
  homepage "https://github.com/Dee-0503/LumiSync"

  depends_on macos: :sonoma

  app "LumiSync.app"

  uninstall launchctl: [
              "com.dee0503.LumiSync",
              "com.dee0503.LumiSyncHelper",
            ],
            delete:    [
              "/Library/LaunchDaemons/com.dee0503.LumiSyncHelper.plist",
              "/Library/PrivilegedHelperTools/com.dee0503.LumiSyncHelper",
            ]

  zap trash: [
    "~/Library/Application Support/LumiSync",
    "~/Library/Preferences/com.dee0503.LumiSync.plist",
  ]
end
