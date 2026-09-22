cask "cloudnetip-spn" do
  version "0.6.6"
  sha256 "8b59cc990858a340c34dc642f070a8b96df7c4293700236b1e698b73fd34ff13"

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
