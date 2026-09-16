# Runs when the packaged app creates its database on first launch, so a new
# user opens onto something rather than an empty list.
Note.find_or_create_by!(title: "Welcome to Notes") do |note|
  note.body = "Add a note below. Every open window shows it at once, over server-sent events."
end
