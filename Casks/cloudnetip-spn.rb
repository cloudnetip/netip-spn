cask "cloudnetip-spn" do
  version "0.8.1"
  sha256 "78ba7b920bd6522f3a7c6815f2b45847f550d89de3cfe3d3acb352d61117211b"

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
