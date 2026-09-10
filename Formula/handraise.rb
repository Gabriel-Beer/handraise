class Handraise < Formula
  desc "Liquid Glass overlay where your Claude Code agents raise their hand"
  homepage "https://github.com/Gabriel-Beer/handraise"
  url "https://github.com/Gabriel-Beer/handraise.git", tag: "v0.3.0", revision: "2477eab1fe12e11e04e557da0b7aeca13d2b2378"
  license "GPL-3.0-or-later"
  head "https://github.com/Gabriel-Beer/handraise.git", branch: "main"

  depends_on macos: :tahoe # Liquid Glass

  def install
    system "swiftc", "-O", "-o", "Handraise", "Overlay.swift"
    system "swiftc", "-O", "-o", "handraise-server", "Server.swift"
    contents = buildpath/"Handraise.app/Contents"
    (contents/"MacOS").install "Handraise"
    (contents/"Resources").install "AppIcon.icns"
    contents.install "Info.plist"
    prefix.install "Handraise.app"
    bin.install "handraise-server"
    bin.install_symlink prefix/"Handraise.app/Contents/MacOS/Handraise" => "handraise-overlay"
  end

  service do
    run opt_prefix/"Handraise.app/Contents/MacOS/Handraise"
    keep_alive successful_exit: false
    log_path var/"log/handraise.log"
    error_log_path var/"log/handraise.log"
  end

  def caveats
    <<~EOS
      Put the app where Finder and Spotlight see it:
        ln -sf #{opt_prefix}/Handraise.app ~/Applications/
      Start the overlay; it stays as a login item:
        brew services start handraise
      Give Claude Code the tools, once:
        claude mcp add --scope user handraise -- #{opt_bin}/handraise-server
    EOS
  end

  test do
    init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18",' \
           '"capabilities":{},"clientInfo":{"name":"brew","version":"0"}}}'
    assert_match "handraise", pipe_output(bin/"handraise-server", "#{init}\n")
  end
end
