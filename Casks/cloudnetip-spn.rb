cask "cloudnetip-spn" do
  version "0.6.1"
  sha256 "f20bb444eb70e16fafa115b50507b0ceb61b63a8b29412eadedae42da42f513e"

  url "https://github.com/cloudnetip/netip-spn/releases/download/v#{version}/Cloudnetip-SPN-#{version}.zip"
  name "Cloudnetip SPN"
  desc "Menubar app for the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"

  depends_on formula: "cloudnetip/tap/cloudnetip-spn"
  depends_on macos: ">= :ventura"

  app "Cloudnetip SPN.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-d", "com.apple.quarantine", "#{appdir}/Cloudnetip SPN.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.cloudnetip.spn.plist",
    "~/Library/Saved Application State/com.cloudnetip.spn.savedState",
  ]
end
