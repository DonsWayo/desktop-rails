# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module DesktopRails
  # Native capabilities, called from Ruby.
  #
  # The bridge runs page-to-shell, which is the right shape on mobile where
  # Hotwire Native has no server to talk to. A desktop app does: its server runs
  # in the same process tree. Without a channel of its own, a background job
  # cannot raise a notification while no page is open, and every native call has
  # to be bounced off a page that may not exist.
  #
  #   DesktopRails::Native.notify(title: "Export finished", body: "invoice.pdf")
  #   DesktopRails::Native.call("window", "resize", width: 1200, height: 900)
  #
  # Outside the desktop shell there is no channel, so `available?` is false and
  # calls return nil rather than raising. The same code then runs unchanged on
  # the web, which is the whole point of sharing a Rails app between the two.
  module Native
    class Error < StandardError; end

    # Raised when the shell answers, but the capability itself failed.
    class CallFailed < Error; end

    Channel = Struct.new(:url, :token, :header, keyword_init: true)

    class << self
      # Read the one line of handshake the shell writes to our stdin.
      #
      # One line, then the pipe stays open: the shell holds it so that closing
      # it is the signal to exit, which is the only thing that survives the
      # shell being force-quit. So this consumes exactly one line and leaves the
      # rest of the stream alone.
      # Set in the child's environment by the shell that spawns it, and only
      # there. It is what distinguishes "a shell is about to write a handshake to
      # my stdin" from every other process that merely has a non-tty stdin.
      HANDSHAKE_ENV = "DESKTOP_RAILS_HANDSHAKE"

      def read_handshake!(io = $stdin, env: ENV)
        return channel if channel

        # Only read when the shell said it would write. Checking "stdin is not a
        # tty" instead is not enough: a CI job, cron, Docker without -t, foreman
        # and most IDE run configurations all hand a process an open pipe that
        # never sends a line, and `gets` then blocks forever. Every `rails
        # db:migrate` in the desktop environment hung that way.
        return nil unless env[HANDSHAKE_ENV] == "stdin"
        return nil unless io

        line = begin
          io.gets
        rescue IOError, Errno::EBADF
          nil
        end
        return nil if line.nil? || line.strip.empty?

        parsed = JSON.parse(line)
        return nil unless parsed["control"] && parsed["token"]

        self.channel = Channel.new(
          url: parsed["control"],
          token: parsed["token"],
          header: parsed["header"] || "x-desktop-token"
        )
      rescue JSON::ParserError
        # Not a handshake. A developer running `rails server` by hand sees this,
        # and the app should still boot.
        nil
      end

      attr_accessor :channel

      def available?
        !channel.nil?
      end

      # Send a bridge message and return the shell's reply.
      #
      # Returns nil when there is no shell, so the same call is a no-op on the
      # web rather than an exception to guard at every call site.
      def call(component, event, **data)
        return nil unless available?

        uri = URI.join(channel.url, "/invoke")
        request = Net::HTTP::Post.new(uri)
        request["content-type"] = "application/json"
        request[channel.header] = channel.token
        request.body = JSON.generate(component: component, event: event, data: data)

        response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 10) do |http|
          http.request(request)
        end

        body = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          {}
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise CallFailed, "#{component}/#{event} failed: #{body["error"] || response.code}"
        end

        body
      rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
        raise Error, "the desktop shell is not answering on #{channel&.url}: #{e.class}"
      end

      # ─── Sugar for the common capabilities ─────────────────────────────────

      # Raise an OS notification. Returns the shell's reply,
      # {"status" => "shown", "id" => ..., "clickable" => ...}, once the
      # platform's notification service has accepted it, and raises CallFailed
      # when there is none or the config turned notifications off.
      #
      # `id` is what a click reports to the app's pages (as
      # desktop-rails:notification-click), and on Linux a later notification
      # with the same id replaces the earlier one rather than stacking.
      def notify(title:, body: nil, id: nil)
        data = { title: title, body: body }
        data[:id] = id.to_s if id
        call("notification", "show", **data)
      end

      # "granted", "denied", "unavailable" or "unknown"; nil outside the shell.
      def notification_permission
        call("notification", "permission")&.fetch("permission", nil)
      end

      def clipboard_write(text)
        call("clipboard", "write-text", text: text)
      end

      def clipboard_read
        call("clipboard", "read-text")&.fetch("text", nil)
      end

      def open_external(url)
        call("shell", "open-external", url: url)
      end

      # The Dock or launcher badge. A count of 0 or nil clears it. The reply's
      # "supported" is false where the platform has no badge (Windows), and the
      # call is then a no-op rather than an error.
      def badge(count)
        return clear_badge if count.nil? || count.to_i.zero?

        call("badge", "set", count: Integer(count))
      end

      # A short text badge. macOS only; elsewhere "supported" is false.
      def badge_label(label)
        call("badge", "set", label: label.to_s)
      end

      def clear_badge
        call("badge", "clear")
      end
    end
  end
end
