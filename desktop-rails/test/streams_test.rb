require_relative "test_helper"
require "rack/mock"
require "timeout"

class StreamsTest < Minitest::Test
  Streams = DesktopRails::Streams

  def teardown
    Streams.disconnect("notes")
    super
  end

  def test_a_broadcast_reaches_every_subscriber_of_that_stream_only
    notes = Streams.subscribe("notes")
    other = Streams.subscribe("tasks")

    assert_equal 1, Streams.broadcast("notes", "<turbo-stream></turbo-stream>")
    assert_equal "<turbo-stream></turbo-stream>", notes.pop(timeout: 1)
    assert_nil other.pop(timeout: 0.05)
  ensure
    Streams.unsubscribe("notes", notes)
    Streams.unsubscribe("tasks", other)
  end

  def test_a_broadcast_with_nobody_listening_goes_nowhere
    assert_equal 0, Streams.broadcast("nobody", "x")
  end

  def test_stream_names_match_turbo_rails
    record = Struct.new(:to_gid_param).new("gid://app/Note/1")
    assert_equal "gid://app/Note/1:comments", Streams.stream_name_from([ record, :comments ])
  end

  def test_only_a_name_the_server_signed_can_be_subscribed_to
    signed = Streams.signed_stream_name("notes")
    assert_equal "notes", Streams.verified_stream_name(signed)
    assert_nil Streams.verified_stream_name("notes")
    assert_nil Streams.verified_stream_name("#{signed}x")
    assert_nil Streams.verified_stream_name(nil)
  end

  def test_an_action_is_a_turbo_stream_with_an_escaped_target
    tag = Streams.action_tag(:prepend, target: %(notes"><script>), html: "<li>hi</li>")
    assert_equal %(<turbo-stream action="prepend" target="notes&quot;&gt;&lt;script&gt;">) +
                 %(<template><li>hi</li></template></turbo-stream>), tag
  end

  def test_a_multi_line_message_is_one_event
    assert_equal "data: <turbo-stream>\ndata:   <template/>\ndata: </turbo-stream>\n\n",
                 Streams.event("<turbo-stream>\n  <template/>\n</turbo-stream>")
  end

  # The endpoint itself, over Rack, the way Puma drives it.

  def test_the_endpoint_streams_broadcasts_as_server_sent_events
    signed = Streams.signed_stream_name("notes")
    request = Thread.new do
      Rack::MockRequest.new(Rails.application).get("/desktop-rails/stream?#{{ name: signed }.to_query}")
    end

    Timeout.timeout(5) { sleep 0.01 until Streams.subscriber_count("notes") == 1 }
    Streams.broadcast_append_to("notes", target: "notes", html: "<li>one</li>")
    Streams.disconnect("notes")
    response = Timeout.timeout(5) { request.value }

    assert_equal 200, response.status
    assert_equal "text/event-stream", response.headers["Content-Type"]
    assert_includes response.body, ": connected"
    assert_includes response.body,
                    %(data: <turbo-stream action="append" target="notes"><template><li>one</li></template></turbo-stream>\n\n)
    assert_equal 0, Streams.subscriber_count("notes"), "a finished stream must unsubscribe"
  end

  def test_the_endpoint_refuses_an_unsigned_name
    response = Rack::MockRequest.new(Rails.application).get("/desktop-rails/stream?name=notes")
    assert_equal 404, response.status
    assert_equal 0, Streams.subscriber_count("notes")
  end

  def test_the_helper_renders_turbos_own_stream_source
    view = ActionView::Base.empty
    html = view.desktop_stream_from("notes")
    assert_match %r{\A<turbo-stream-source src="/desktop-rails/stream\?name=[^"]+"></turbo-stream-source>\z}, html

    src = CGI.unescapeHTML(html[/src="([^"]+)"/, 1])
    name = Rack::Utils.parse_query(URI(src).query)["name"]
    assert_equal "notes", Streams.verified_stream_name(name)
  end
end
