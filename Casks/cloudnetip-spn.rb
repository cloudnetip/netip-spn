cask "cloudnetip-spn" do
  version "0.6.4"
  sha256 "544d843cd84589aee0ad3eeff2db40635a1c5971cce3f5680a32628e78a523b9"

  url "https://github.com/cloudnetip/netip-spn/releases/download/v#{version}/Cloudnetip-SPN-#{version}.zip"
  name "Cloudnetip SPN"
  desc "Menubar app for the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"

  depends_on formula: "cloudnetip/tap/cloudnetip-spn"
  depends_on macos: :ventura

  app "Cloudnetip SPN.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-d", "com.apple.quarantine", "{{appdir}}/Cloudnetip SPN.app"],
        must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/com.cloudnetip.spn.plist",
    "~/Library/Saved Application State/com.cloudnetip.spn.savedState",
  ]
end
