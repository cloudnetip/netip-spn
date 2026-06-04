class CloudnetipSpn < Formula
  desc "CLI for managing the Cloudnetip Shared Private Network"
  homepage "https://github.com/cloudnetip/netip-spn"
  url "https://github.com/cloudnetip/netip-spn/archive/refs/tags/v0.5.0.tar.gz"
  sha256 "142c43393c07fd798e538a06bc2070ca1b8df3f7c6f1f33d1c3d0b40624b64ce"
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
