Rails.application.routes.draw do
  mount PermissionForge::Engine, at: '/permission_forge'

  # Host-app fixtures for controller-action discovery and the action guard.
  # No root route: the admin's "Back to app" default relies on its absence.
  resources :customers, only: %i[index show] do
    collection { get :export }
    member { post :archive }
    resource :merge, only: :create, controller: 'customers/merges'
  end
  resources :reports, only: :index

  # Audit integration suite: a host controller using the runtime guards.
  scope 'pf_audit_probe', controller: 'pf_audit_probes' do
    get 'customers', action: :index
    get 'customers/:id', action: :show
    patch 'customers/:id', action: :update
  end
end
