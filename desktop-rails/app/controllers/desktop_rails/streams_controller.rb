module DesktopRails
  # GET /desktop-rails/stream?name=<signed stream name>
  #
  # The server-sent events endpoint a <turbo-stream-source> subscribes to. See
  # DesktopRails::Streams for why a desktop app streams this way rather than over
  # Action Cable.
  class StreamsController < ActionController::Base
    include ActionController::Live

    # A comment line this often keeps the connection from looking idle, and is
    # how a window that has gone away is noticed: the write fails.
    HEARTBEAT_SECONDS = 15

    def show
      name = Streams.verified_stream_name(params[:name])
      return head(:not_found) if name.nil?

      response.headers["Content-Type"] = "text/event-stream"
      # Both, so that nothing between here and the webview buffers the stream
      # waiting for it to finish: Rack::ETag holds back any response without a
      # cache validator or no-cache.
      response.headers["Cache-Control"] = "no-cache"
      response.headers["Last-Modified"] = Time.now.httpdate
      response.headers["X-Accel-Buffering"] = "no"

      queue = Streams.subscribe(name)
      # Sent at once, so the page's EventSource opens now rather than at the
      # first broadcast, and a broadcast that follows is not lost to a race.
      response.stream.write("retry: 1000\n: connected\n\n")

      loop do
        message = queue.pop(timeout: HEARTBEAT_SECONDS)
        break if message.equal?(Streams::CLOSE)

        response.stream.write(message.nil? ? ": heartbeat\n\n" : Streams.event(message))
      end
    rescue ActionController::Live::ClientDisconnected, IOError, Errno::EPIPE, Errno::ECONNRESET
      # The window closed or navigated away; nothing to do but let go.
    ensure
      Streams.unsubscribe(name, queue) if queue
      response.stream.close
    end
  end
end
