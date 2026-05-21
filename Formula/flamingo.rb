class Flamingo < Formula
  desc "Terminal modal text editor written in Zig"
  homepage "https://github.com/spaghettifunk/flamingo"

  # v1.0.0 has not been released yet. After cutting the release, replace the
  # version in this URL if needed and replace the all-zero sha256 with the
  # source tarball checksum printed by the release workflow or `make homebrew-sha`.
  url "https://github.com/spaghettifunk/flamingo/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  license "MIT"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe"
    bin.install "zig-out/bin/flamingo"
  end

  test do
    assert_match "flamingo", shell_output("#{bin}/flamingo --version")
    assert_match "Usage: flamingo", shell_output("#{bin}/flamingo --help")
  end
end
