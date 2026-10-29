# Optional: the CLI alone, built from source. Most users should take the cask, which already
# links `labelize` onto PATH. Requires the source repo to be public.
class LabelizeCli < Formula
  desc "Print any PDF, SVG or image as a thermal printer label (command-line)"
  homepage "https://github.com/fermium/peel-good-inc"
  url "https://github.com/fermium/peel-good-inc/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on xcode: ["26.0", :build]
  depends_on macos: :sequoia

  conflicts_with cask: "peel-good-inc", because: "the cask already installs the labelize binary"

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "labelize"
    bin.install ".build/release/labelize"
  end

  test do
    system bin/"labelize", "--list-sizes" # TODO: confirm this exits 0 on a Mac with no printers
  end
end
