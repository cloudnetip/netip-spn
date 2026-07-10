class CloudnetipSpn < Formula
  desc "CLI for managing the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"
  url "https://github.com/cloudnetip/netip-spn/archive/refs/tags/v0.6.3.tar.gz"
  sha256 "3d13d21b1d3e26de0dc833b90a38cc861fa0aae0e16135912b41cc9b7c6e5832"
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
