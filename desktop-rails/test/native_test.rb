# frozen_string_literal: true

require "test_helper"
require "socket"
require "timeout"
require "json"

# Exercises the control channel from the Ruby side against a stub shell, so the
# protocol is tested without building the Tauri app.
class NativeTest < Minitest::Test
  TOKEN = "f" * 64

  def setup
    @received = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve_loop }
    DesktopRails::Native.channel = nil
  end

  def teardown
    @thread&.kill
    @server&.close
    DesktopRails::Native.channel = nil
  end

  # ─── outside the shell ──────────────────────────────────────────────────

  def test_is_unavailable_without_a_handshake
    refute_predicate DesktopRails::Native, :available?
  end

  def test_calls_are_a_no_op_on_the_web_rather_than_an_exception
    # The same Rails app serves the web, where there is no shell. Raising would
    # force a guard at every call site.
    assert_nil DesktopRails::Native.notify(title: "ignored")
    assert_nil DesktopRails::Native.call("window", "resize", width: 1)
  end

  # ─── the handshake ──────────────────────────────────────────────────────

  def test_reads_the_handshake_and_becomes_available
    with_handshake
    assert_predicate DesktopRails::Native, :available?
    assert_equal "http://127.0.0.1:#{@port}", DesktopRails::Native.channel.url
  end

  def test_consumes_exactly_one_line_of_stdin
    # The shell keeps the pipe open after the handshake so that closing it is
    # the signal to exit. Reading past our line would break that.
    reader, writer = IO.pipe
    writer.puts handshake_line
    writer.puts "reserved for the exit watchdog"
    writer.close

    DesktopRails::Native.read_handshake!(reader, env: { "DESKTOP_RAILS_HANDSHAKE" => "stdin" })

    assert_equal "reserved for the exit watchdog", reader.gets.strip
  end

  def test_ignores_a_line_that_is_not_a_handshake
    reader, writer = IO.pipe
    writer.puts "Puma starting in single mode..."
    writer.close

    assert_nil DesktopRails::Native.read_handshake!(reader, env: { "DESKTOP_RAILS_HANDSHAKE" => "stdin" })
    refute_predicate DesktopRails::Native, :available?
  end

  def test_does_not_touch_stdin_unless_a_shell_said_it_would_write
    # The regression. A CI job, cron, Docker without -t and foreman all give a
    # process an open pipe that never sends a line. Reading it blocked forever,
    # so every `rails db:migrate` in the desktop environment hung.
    reader, _writer = IO.pipe # writer held open and silent: gets would block

    result = Timeout.timeout(2) { DesktopRails::Native.read_handshake!(reader, env: {}) }

    assert_nil result
    refute_predicate DesktopRails::Native, :available?
  ensure
    reader&.close
    _writer&.close
  end

  def test_reads_the_handshake_when_the_shell_signals_it
    reader, writer = IO.pipe
    writer.puts handshake_line
    writer.close

    DesktopRails::Native.read_handshake!(reader, env: { "DESKTOP_RAILS_HANDSHAKE" => "stdin" })

    assert_predicate DesktopRails::Native, :available?
  end

  # ─── calls ──────────────────────────────────────────────────────────────

  def test_notify_sends_the_notification_component
    with_handshake
    DesktopRails::Native.notify(title: "Export finished", body: "invoice.pdf")

    message = @received.pop
    assert_equal "notification", message["component"]
    assert_equal "show", message["event"]
    assert_equal "Export finished", message["data"]["title"]
    assert_equal "invoice.pdf", message["data"]["body"]
  end

  def test_notify_sends_exactly_the_payload_the_shell_parses
    # Kept in step with notifications.rs, whose test parses this same body. A
    # nil body goes over as null, which the shell reads as no body.
    with_handshake
    DesktopRails::Native.notify(title: "Export finished", id: :export)

    message = @received.pop
    assert_equal({ "component" => "notification", "event" => "show",
                   "data" => { "title" => "Export finished", "body" => nil, "id" => "export" } }, message)
  end

  def test_notify_leaves_the_id_out_when_none_is_given
    with_handshake
    DesktopRails::Native.notify(title: "Done", body: "3 files")

    refute @received.pop["data"].key?("id"), "the shell generates one"
  end

  def test_notify_returns_what_the_shell_said
    with_handshake
    reply = DesktopRails::Native.notify(title: "Done", id: "sync")

    assert_equal "shown", reply["status"]
    assert_equal "sync", reply["id"]
  end

  def test_a_notification_the_os_cannot_show_raises
    # With no notification service the shell answers 500, and a job that
    # notifies on completion should learn that nobody saw it.
    with_handshake
    error = assert_raises(DesktopRails::Native::CallFailed) do
      DesktopRails::Native.notify(title: "no daemon")
    end
    assert_match(/not running/, error.message)
  end

  def test_notification_permission_reads_the_shells_answer
    with_handshake
    assert_equal "granted", DesktopRails::Native.notification_permission
    assert_equal "permission", @received.pop["event"]
  end

  def test_badge_sets_a_count_and_zero_clears
    with_handshake
    DesktopRails::Native.badge(3)
    assert_equal({ "component" => "badge", "event" => "set", "data" => { "count" => 3 } }, @received.pop)

    DesktopRails::Native.badge(0)
    assert_equal({ "component" => "badge", "event" => "clear", "data" => {} }, @received.pop)

    DesktopRails::Native.badge_label("new")
    assert_equal({ "label" => "new" }, @received.pop["data"])
  end

  def test_call_reaches_any_component_with_its_payload
    with_handshake
    DesktopRails::Native.call("window", "resize", width: 1200, height: 900)

    message = @received.pop
    assert_equal "window", message["component"]
    assert_equal({ "width" => 1200, "height" => 900 }, message["data"])
  end

  def test_a_window_resize_reports_the_size_the_shell_actually_applied
    # The shell clamps a resize to the minimums the app configured, so what came
    # back is the only way Ruby knows what it got. (The clamping itself is the
    # shell's, and is tested there; this is the half that has to survive the
    # trip home.)
    with_handshake
    reply = DesktopRails::Native.call("window", "resize", width: 100, height: 100)

    assert_equal "ok", reply["status"]
    assert_equal 800, reply["width"]
    assert_equal 600, reply["height"]
  end

  def test_a_capability_the_shell_refuses_is_raised_rather_than_returned
    # The shell answers a refused resize with 500 and a reason, and a job that
    # asked for it should hear about that rather than carry on as if it worked.
    with_handshake
    error = assert_raises(DesktopRails::Native::CallFailed) do
      DesktopRails::Native.call("window", "resize", width: 0, height: 0)
    end

    assert_match(%r{window/resize failed}, error.message)
    assert_match(/not a usable size/, error.message)
  end

  def test_a_reply_value_comes_back_to_ruby
    with_handshake
    assert_equal "from the clipboard", DesktopRails::Native.clipboard_read
  end

  # ─── failure ────────────────────────────────────────────────────────────

  def test_a_wrong_token_is_refused_by_the_shell
    with_handshake(token: "0" * 64)
    error = assert_raises(DesktopRails::Native::CallFailed) do
      DesktopRails::Native.notify(title: "should not arrive")
    end
    assert_match(/bad token/, error.message)
  end

  def test_a_shell_that_is_not_answering_gives_a_clear_error
    DesktopRails::Native.channel = DesktopRails::Native::Channel.new(
      url: "http://127.0.0.1:1", token: TOKEN, header: "x-desktop-token"
    )
    error = assert_raises(DesktopRails::Native::Error) do
      DesktopRails::Native.notify(title: "x")
    end
    assert_match(/not answering/, error.message)
  end

  private

  def handshake_line(token: TOKEN)
    JSON.generate(
      protocol: "1.0",
      control: "http://127.0.0.1:#{@port}",
      token: token,
      header: "x-desktop-token"
    )
  end

  def with_handshake(token: TOKEN)
    reader, writer = IO.pipe
    writer.puts handshake_line(token: token)
    DesktopRails::Native.read_handshake!(reader, env: { "DESKTOP_RAILS_HANDSHAKE" => "stdin" })
  end

  # A stand-in for the shell's control listener, matching control.rs.
  def serve_loop
    loop do
      conn = @server.accept
      head = +""
      head << conn.readpartial(1) until head.end_with?("\r\n\r\n")
      length = head[/content-length:\s*(\d+)/i, 1].to_i
      body = length.positive? ? conn.read(length) : ""

      if head[/x-desktop-token:\s*(\S+)/i, 1] != TOKEN
        write(conn, "401 Unauthorized", { error: "bad token" })
      elsif head[%r{^POST (\S+)}, 1] != "/invoke"
        write(conn, "404 Not Found", { error: "POST /invoke only" })
      else
        message = JSON.parse(body)
        @received << message
        status, payload = reply_to(message)
        write(conn, status, payload)
      end
      conn.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  # What the shell answers. Only the window component needs more than "ok":
  # resize reports the size it applied after the app's minimums, and refuses a
  # size nobody could use — both of which Ruby has to carry back to its caller.
  def reply_to(message)
    return notification_reply(message) if message["component"] == "notification"
    return [ "200 OK", { status: "ok", text: "from the clipboard" } ] unless
      message["component"] == "window" && message["event"] == "resize"

    width = message["data"]["width"].to_i
    height = message["data"]["height"].to_i
    if width <= 0 || height <= 0
      [ "500 Internal Server Error", { error: "Refused: #{width}x#{height} is not a usable size" } ]
    else
      [ "200 OK", { status: "ok", width: [ width, 800 ].max, height: [ height, 600 ].max } ]
    end
  end

  # What notifications.rs answers: the permission it read, the id it showed,
  # or a refusal when the platform has no notification service.
  def notification_reply(message)
    data = message["data"] || {}
    return [ "200 OK", { status: "ok", permission: "granted" } ] if message["event"] == "permission"
    if data["title"] == "no daemon"
      return [ "500 Internal Server Error",
               { error: "The notification service refused or is not running: ServiceUnknown" } ]
    end

    [ "200 OK", { status: "shown", id: data["id"] || "notification-1", clickable: true } ]
  end

  def write(conn, status, payload)
    json = JSON.generate(payload)
    conn.print "HTTP/1.1 #{status}\r\ncontent-type: application/json\r\n" \
               "content-length: #{json.bytesize}\r\nconnection: close\r\n\r\n#{json}"
  end
end
