class Lumisync < Formula
  desc "Developer preview of the LumiSync brightness synchronization core"
  homepage "https://github.com/Dee-0503/LumiSync"
  url "https://github.com/Dee-0503/LumiSync/releases/download/v0.1.0-alpha.1/LumiSync-0.1.0-alpha.1-arm64.tar.gz"
  sha256 "c87bf0231f9a17d69d232fb5187a7e1e5fa71a277f6088f3f75b4abc3e457595"
  license :cannot_represent

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    bin.install "lumisync"
  end

  test do
    assert_match "LumiSync 0.1.0", shell_output("#{bin}/lumisync")
  end
end
