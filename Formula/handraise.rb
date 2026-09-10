class Handraise < Formula
  desc "Liquid Glass overlay where your Claude Code agents raise their hand"
  homepage "https://github.com/Gabriel-Beer/handraise"
  url "https://github.com/Gabriel-Beer/handraise.git", tag: "v0.3.0", revision: "2477eab1fe12e11e04e557da0b7aeca13d2b2378"
  license "GPL-3.0-or-later"
  head "https://github.com/Gabriel-Beer/handraise.git", branch: "main"

  depends_on macos: :tahoe # Liquid Glass

  def install
    system "swiftc", "-O", "-o", "handraise-overlay", "Overlay.swift"
    system "swiftc", "-O", "-o", "handraise-server", "Server.swift"
    bin.install "handraise-overlay", "handraise-server"
  end

  service do
    run opt_bin/"handraise-overlay"
    keep_alive successful_exit: false
    log_path var/"log/handraise.log"
    error_log_path var/"log/handraise.log"
  end

  def caveats
    <<~EOS
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
