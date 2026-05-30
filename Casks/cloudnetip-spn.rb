cask "cloudnetip-spn" do
  version "0.2.0"
  sha256 "f967635d1b699f8dcec77f6a667a317e8017860c555ad4173f3c92020df60b87"

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
