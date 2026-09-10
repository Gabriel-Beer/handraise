class Handraise < Formula
  desc "Liquid Glass overlay where your Claude Code agents raise their hand"
  homepage "https://github.com/Gabriel-Beer/handraise"
  url "https://github.com/Gabriel-Beer/handraise.git", tag: "v0.1.0", revision: "ba8c345a07c0fc2d6ec9f8b14d8665036c23fd11"
  license "MIT"
  head "https://github.com/Gabriel-Beer/handraise.git", branch: "main"

  depends_on macos: :tahoe # Liquid Glass
  depends_on "uv"

  def install
    system "swiftc", "-O", "-o", "handraise-overlay", "Overlay.swift"
    bin.install "handraise-overlay"
    libexec.install "server.py"
    (bin/"handraise-server").write <<~SH
      #!/bin/sh
      exec "#{formula_opt_bin("uv")}/uv" run --script "#{libexec}/server.py" "$@"
    SH
    chmod 0755, bin/"handraise-server"
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
