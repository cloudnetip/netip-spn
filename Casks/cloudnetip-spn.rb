cask "cloudnetip-spn" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_APP_ZIP"

  url "https://github.com/cloudnetip/netip-spn/releases/download/v#{version}/CloudnetipSPN-#{version}.zip"
  name "Cloudnetip SPN"
  desc "Menubar app for the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"

  depends_on formula: "cloudnetip/spn/cloudnetip-spn"
  depends_on macos: ">= :ventura"

  app "CloudnetipSPN.app"

  zap trash: [
    "~/Library/Preferences/com.cloudnetip.spn.plist",
    "~/Library/Saved Application State/com.cloudnetip.spn.savedState",
  ]
end
