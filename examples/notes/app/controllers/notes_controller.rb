class NotesController < ApplicationController
  def index
    @notes = Note.order(created_at: :desc)
    @note = Note.new
  end

  def create
    @note = Note.new(note_params)

    if @note.save
      notify_saved(@note)
      respond_to do |format|
        # Only the form is reset here; the note itself arrives over the stream.
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace("note_form", partial: "form", locals: { note: Note.new })
        end
        format.html { redirect_to root_path }
      end
    else
      render turbo_stream: turbo_stream.replace("note_form", partial: "form", locals: { note: @note }),
             status: :unprocessable_entity
    end
  end

  private

  def note_params
    params.expect(note: %i[title body])
  end

  # A native notification, raised from Ruby over the shell's control channel.
  # Outside the shell there is no channel and this does nothing; a shell that
  # cannot show one must not cost the user their note.
  def notify_saved(note)
    DesktopRails::Native.notify(title: "Note saved", body: note.title)
  rescue DesktopRails::Native::Error => e
    Rails.logger.warn("Could not show a notification: #{e.message}")
  end
end
