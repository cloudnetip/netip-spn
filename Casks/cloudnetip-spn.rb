cask "cloudnetip-spn" do
  version "0.1.0"
  sha256 "8ea2805bc4fec856176f64ed50059112446bdcc6e9a32922509634123da0b42c"

  url "https://github.com/cloudnetip/netip-spn/releases/download/v#{version}/CloudnetipSPN-#{version}.zip"
  name "Cloudnetip SPN"
  desc "Menubar app for the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"

  depends_on formula: "cloudnetip/spn/cloudnetip-spn"
  depends_on macos: ">= :ventura"

  app "CloudnetipSPN.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-d", "com.apple.quarantine", "#{appdir}/CloudnetipSPN.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.cloudnetip.spn.plist",
    "~/Library/Saved Application State/com.cloudnetip.spn.savedState",
  ]
end
