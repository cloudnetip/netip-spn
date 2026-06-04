class CloudnetipSpn < Formula
  desc "CLI for managing the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"
  url "https://github.com/cloudnetip/netip-spn/archive/refs/tags/v0.6.1.tar.gz"
  sha256 "27bd3e4ac546f3e032553eb3eca0956f06045b2aa152ff51ed22136e14cf3ae5"
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
