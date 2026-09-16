# What the native bridge answered, in both directions, kept in the data
# directory where anything outside the app can read it.
#
# The page reports what the shell told its JavaScript, and then that the
# server's reply reached it over the stream; #window asks the shell from Ruby.
class Native::ReportsController < ApplicationController
  KINDS = %w[javascript stream].freeze

  # POST /native/reports
  def create
    kind = params.require(:kind)
    return head(:unprocessable_entity) unless KINDS.include?(kind)

    report = write_report(kind, ok: params[:ok] == true, detail: params[:detail]&.to_unsafe_h)

    # The reply to a JavaScript report goes back over the stream, not in this
    # response, so its arriving at all proves the stream reached the window.
    if kind == "javascript"
      DesktopRails::Streams.broadcast_replace_to "native", target: "native_confirmation",
                                                 partial: "native/confirmation", locals: { report: }
    end
    head :no_content
  end

  # GET /native/window
  def window
    state = DesktopRails::Native.call("window", "state")
    ok = state.is_a?(Hash) && state["status"] == "ok"
    report = write_report("ruby", ok:, detail: { available: DesktopRails::Native.available?, state: })
    render json: report, status: ok ? :ok : :service_unavailable
  rescue DesktopRails::Native::Error => e
    report = write_report("ruby", ok: false, detail: { error: e.message })
    render json: report, status: :service_unavailable
  end

  private

  def write_report(kind, ok:, detail:)
    report = { kind:, ok:, detail:, user_agent: request.user_agent, at: Time.current.iso8601 }
    dir = DesktopRails.data_dir(create: true).join("native-reports")
    FileUtils.mkdir_p(dir)
    dir.join("#{kind}.json").write(JSON.pretty_generate(report))
    report
  end
end
