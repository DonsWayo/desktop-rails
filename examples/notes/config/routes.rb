Rails.application.routes.draw do
  mount DesktopRails::Engine => "/desktop-rails"

  root "notes#index"
  resources :notes, only: %i[index create]

  # The native bridge, both ways. The page reports what the shell told its
  # JavaScript; the server asks the shell itself, from Ruby.
  namespace :native do
    post "reports", to: "reports#create"
    get "window", to: "reports#window"
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
