# Homebrew formula, published in the tap repository stlk0/homebrew-tap as
# Formula/rndis-tether-app.rb. To release: tag vX.Y.Z, take the sha256 of GitHub's
# archive of the tag, and update url and sha256 here and in stlk0/homebrew-tap.
class RndisTetherApp < Formula
  desc "Menu bar status for rndis-tether (Android USB tethering)"
  homepage "https://github.com/stlk0/rndis-tether-app"
  url "https://github.com/stlk0/rndis-tether-app/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "b6b5248489fe06d8f890e62d5eeeb4ac2544d56024a1277e2fde8204979a0b44"
  license "MIT"

  depends_on macos: :ventura
  depends_on "stlk0/tap/rndis-tether"

  def install
    system "make", "app", "ARCHS=#{Hardware::CPU.arch}", "VERSION=#{version}",
           "CLI_PATH=#{formula_opt_bin("stlk0/tap/rndis-tether")}/rndis-tether"
    prefix.install "build/RNDIS Tether.app"
  end

  def caveats
    <<~EOS
      Start the menu app (afterwards it starts at login by itself):
        open "#{opt_prefix}/RNDIS Tether.app"
      It offers to install the rndis-tether service; or run: sudo rndis-tether install
      Optional, to see it in Finder's Applications folder:
        ln -sf "#{opt_prefix}/RNDIS Tether.app" /Applications/
      Before `brew uninstall`, turn off Open at login in its settings.
    EOS
  end

  test do
    app = prefix/"RNDIS Tether.app"
    assert_path_exists app/"Contents/MacOS/RNDIS Tether"
    system "codesign", "--verify", "--strict", app
    cli = formula_opt_bin("stlk0/tap/rndis-tether")/"rndis-tether"
    plist = app/"Contents/Info.plist"
    assert_equal cli.to_s, shell_output("plutil -extract RTCLIPath raw -o - '#{plist}'").chomp
    assert_equal version.to_s, shell_output("plutil -extract CFBundleShortVersionString raw -o - '#{plist}'").chomp
  end
end
