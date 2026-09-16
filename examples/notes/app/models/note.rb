class Note < ApplicationRecord
  validates :title, presence: true

  # Every open window shows the new note, including the one that created it,
  # over server-sent events rather than Action Cable: see DesktopRails::Streams.
  after_create_commit do
    DesktopRails::Streams.broadcast_prepend_to "notes", target: "notes",
                                               partial: "notes/note", locals: { note: self }
  end
end
