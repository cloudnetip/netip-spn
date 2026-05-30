cask "cloudnetip-spn" do
  version "0.3.0"
  sha256 "3b5e893ed3e13ee0746ffbd49f0636d80367ada95faaca54597707279c981778"

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
