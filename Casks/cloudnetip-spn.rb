cask "cloudnetip-spn" do
  version "0.4.0"
  sha256 "14bd9eecb3659b044df81af04f28cdd5539fb2a9f7359280edb5f9ffcbaa2a9d"

  url "https://github.com/cloudnetip/netip-spn/releases/download/v#{version}/Cloudnetip-SPN-#{version}.zip"
  name "Cloudnetip SPN"
  desc "Menubar app for the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"

  depends_on formula: "cloudnetip/spn/cloudnetip-spn"
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
