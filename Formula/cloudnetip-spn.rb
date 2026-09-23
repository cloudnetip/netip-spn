class CloudnetipSpn < Formula
  desc "CLI for managing the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"
  url "https://github.com/cloudnetip/netip-spn/archive/refs/tags/v0.8.0.tar.gz"
  sha256 "0f3c78d286e5f34a520e3ded1ba847dca1cdd34242528828d6a96e16e17e252b"
  license "MIT"
  head "https://github.com/cloudnetip/netip-spn.git", branch: "main"

  depends_on "go" => :build
  depends_on "wireguard-tools"

  def install
    ldflags = "-s -w -X main.version=#{version}"
    system "go", "build", *std_go_args(ldflags: ldflags, output: bin/"netip-spn"), "."
  end

  test do
    assert_match "netip-spn", shell_output("#{bin}/netip-spn version")
    assert_match "disconnected", shell_output("#{bin}/netip-spn status")
  end
end
