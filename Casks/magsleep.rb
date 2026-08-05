cask "magsleep" do
  version "1.2.2"
  sha256 "74da6a8d7e73d7c9dd4789a24ad2e120745f5d750b00b102067bff706a90ee7c"

  url "https://github.com/realAbitbol/MagSleep/releases/download/v#{version}/MagSleep-#{version}.dmg"
  name "MagSleep"
  desc "Turn the MagSafe LED off while your Mac sleeps, or keep it off completely"
  homepage "https://github.com/realAbitbol/MagSleep"

  livecheck do
    url "https://github.com/realAbitbol/MagSleep/releases"
    strategy :github_latest
  end

  app "MagSleep.app"

  # MagSleep updates itself via Sparkle; brew should not nag about it.
  auto_updates true

  # The privileged helper (removed by the app's "Uninstall MagSleep…" item,
  # which needs an admin password) is intentionally not touched by zap.
  zap trash: [
    "~/Library/Preferences/com.magsleep.MagSleep.plist",
    "~/Library/Caches/com.magsleep.MagSleep",
  ]
end
