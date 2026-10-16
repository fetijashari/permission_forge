Rails.application.routes.draw do
  resources :passwords, param: :token, only: :new
  resource :session
  resources :customers
  get "public", to: "public_customers#index"
  namespace :api do
    resources :customers, only: %i[index show]
  end
  mount PermissionForge::Engine, at: "/permissions"

  root "customers#index"
end
