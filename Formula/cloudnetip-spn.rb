class CloudnetipSpn < Formula
  desc "CLI for managing the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"
  url "https://github.com/cloudnetip/netip-spn/archive/refs/tags/v0.6.5.tar.gz"
  sha256 "9e99fd1c4ddaba16c1db21efdaac47696d67bf7a63f636b6cbfd020bec22f2dc"
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
