class Sweep < Formula
  desc "Menu bar uninstaller that also removes the files an app leaves behind"
  homepage "https://github.com/pandeynmn/sweep"
  url "https://github.com/pandeynmn/sweep/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "4b70de3ef2a29465bafb5083bfaf1083ab4a1cb55c54207cbd9f169d809141a0"
  head "https://github.com/pandeynmn/sweep.git", branch: "main"
  license :cannot_represent # free for personal use, see LICENSE

  depends_on macos: :sonoma

  def install
    # Ad-hoc: users don't have Nomad's signing identity. macOS resets privacy grants on each upgrade because of it.
    ENV["SIGN_ID"] = "-"
    ENV["SWIFTFLAGS"] = "-disable-sandbox"
    ENV["NOLINT"] = "1"
    system "./build.sh"
    prefix.install "build/Sweep.app"
    bin.install_symlink prefix/"Sweep.app/Contents/MacOS/Sweep" => "sweep"
  end

  def caveats
    <<~EOS
      To use the menu bar app and the Finder Quick Actions, link it into ~/Applications and open it once:
        ln -sfn #{opt_prefix}/Sweep.app ~/Applications/Sweep.app
        open ~/Applications/Sweep.app

      Sweep is ad-hoc signed when built by Homebrew, so after each upgrade macOS asks again for
      App Management and Full Disk Access.
    EOS
  end

  test do
    assert_equal "ok", shell_output("#{bin}/sweep --selftest").strip
  end
end
