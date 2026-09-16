# frozen_string_literal: true

require "erb"
require "json"

module DesktopRails
  # Turbo Streams over server-sent events, in process.
  #
  # A Rails app broadcasts Turbo Streams through Action Cable, which is a
  # WebSocket server with a pub/sub adapter behind it. A packaged desktop app is
  # one Puma process serving one person: there is nothing to fan out across, no
  # Redis to reach, and the solid_cable database would be written to only to be
  # read back by the same process. Server-sent events are plain HTTP, which the
  # webview already speaks, and Turbo subscribes to them natively through
  # <turbo-stream-source>.
  #
  #   <%= desktop_stream_from "notes" %>                         # in a view
  #   DesktopRails::Streams.broadcast_prepend_to("notes", target: "notes",
  #                                             partial: "notes/note", locals: { note: })
  #
  # Subscribers live in this process's memory, so a broadcast reaches every
  # window of this app and nothing else — which, for a desktop app, is all of
  # them. A broadcast with no window open goes nowhere, as it would over Cable.
  module Streams
    # Sent to a subscriber to end its stream, so the request thread finishes
    # instead of waiting on a queue nobody will write to again.
    CLOSE = Object.new.freeze

    @subscribers = Hash.new { |hash, name| hash[name] = [] }
    @lock = Mutex.new

    class << self
      # The stream name a set of streamables maps to: records by their global
      # id where they have one, anything else by its string form. The same
      # shape turbo-rails uses, so a name means the same thing in both.
      def stream_name_from(streamables)
        Array(streamables).flatten.map do |streamable|
          streamable.respond_to?(:to_gid_param) ? streamable.to_gid_param : streamable.to_param
        end.join(":")
      end

      # Signed, so a page can only subscribe to streams the server rendered a
      # subscription for, the way turbo-rails signs Cable stream names.
      def signed_stream_name(streamables)
        verifier.generate(stream_name_from(streamables))
      end

      def verified_stream_name(signed)
        return nil if signed.nil? || signed.empty?

        verifier.verified(signed)
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        nil
      end

      def subscribe(name)
        queue = Thread::Queue.new
        @lock.synchronize { @subscribers[name] << queue }
        queue
      end

      def unsubscribe(name, queue)
        @lock.synchronize do
          @subscribers[name].delete(queue)
          @subscribers.delete(name) if @subscribers[name].empty?
        end
      end

      def subscriber_count(streamables)
        name = stream_name_from(streamables)
        @lock.synchronize { @subscribers.key?(name) ? @subscribers[name].size : 0 }
      end

      # Deliver already-rendered Turbo Stream markup to every subscriber.
      # Returns how many received it.
      def broadcast(streamables, content)
        name = stream_name_from(streamables)
        queues = @lock.synchronize { @subscribers.key?(name) ? @subscribers[name].dup : [] }
        queues.each { |queue| queue << content.to_s }
        queues.size
      end

      # End every open stream for these streamables. The page's EventSource
      # reconnects on its own, so this is a way to shed subscribers, not to
      # silence a window.
      def disconnect(streamables)
        name = stream_name_from(streamables)
        queues = @lock.synchronize { @subscribers.key?(name) ? @subscribers[name].dup : [] }
        queues.each { |queue| queue << CLOSE }
        queues.size
      end

      # Render and broadcast one Turbo Stream action.
      #
      #   broadcast_action_to "notes", action: :prepend, target: "notes",
      #                       partial: "notes/note", locals: { note: }
      #   broadcast_action_to "notes", action: :remove, target: note
      #
      # `target` may be a DOM id or a record, which is turned into its dom_id.
      # Rendering options go to the application's renderer, so partials are
      # looked up exactly as a controller would.
      def broadcast_action_to(streamables, action:, target:, html: nil, **rendering)
        broadcast(streamables, action_tag(action, target: target, html: html, **rendering))
      end

      %i[append prepend replace update remove before after].each do |action|
        define_method(:"broadcast_#{action}_to") do |streamables, target:, **options|
          broadcast_action_to(streamables, action: action, target: target, **options)
        end
      end

      def action_tag(action, target:, html: nil, **rendering)
        template = html || (rendering.empty? ? "" : render(**rendering))
        target_id = dom_target(target)
        %(<turbo-stream action="#{ERB::Util.html_escape(action)}" target="#{ERB::Util.html_escape(target_id)}">) +
          %(<template>#{template}</template></turbo-stream>)
      end

      # One server-sent event carrying `content`. Every line of it gets its own
      # data field, which is how the format carries a multi-line payload; the
      # browser joins them back with newlines.
      def event(content)
        content.to_s.split("\n", -1).map { |line| "data: #{line}\n" }.join + "\n"
      end

      private

      def verifier
        Rails.application.message_verifier("desktop_rails/streams")
      end

      def dom_target(target)
        if target.respond_to?(:to_key)
          ActionView::RecordIdentifier.dom_id(target)
        else
          target.to_s
        end
      end

      def render(**options)
        renderer = defined?(::ApplicationController) ? ::ApplicationController : ActionController::Base
        renderer.render(**options)
      end
    end
  end
end
