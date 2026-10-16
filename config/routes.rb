PermissionForge::Engine.routes.draw do
  # Engine-served CSS/JS/brand files — no host asset pipeline required.
  get 'pf-assets/:file', to: 'assets#show', as: :pf_asset, constraints: { file: /[\w.-]+/ }, format: false

  root to: 'home#index'

  # Per-browser admin preferences (theme, dismissed helper banners).
  resource :preferences, only: :update

  get 'settings', to: 'settings#show', as: :settings
  get 'field_lookup', to: 'field_lookups#show', as: :field_lookup

  # The audit log (read-only): the filtered log and its CSV / JSON export, one
  # event by uuid, and the "who holds what" export.
  resources :audit_events, path: 'audit', only: %i[index show] do
    collection do
      get :holdings
    end
  end

  # Home "needs attention": remove expired assignments (dry run shown inline on Home).
  delete 'maintenance/cleanup', to: 'maintenance#cleanup', as: :maintenance_cleanup

  resources :people, only: %i[index show] do
    member do
      get :remove_all, action: :confirm_remove_all
      delete :remove_all
      post :refresh_cache
      get :consent, action: :consent_preview
      post :consent, action: :withdraw_consent
      get :erasure, action: :erasure_preview
      post :erasure, action: :erase
    end
  end

  resources :assignments, only: %i[new create update destroy] do
    member do
      get :remove, action: :confirm_destroy
      post :keep
    end
    collection do
      post :restore
      post :undo
    end
  end

  resources :permission_sets, only: %i[index new create show destroy] do
    member do
      post :review
      patch :apply
      post :duplicate
      get :delete, action: :confirm_destroy
      get :switch_mode, action: :confirm_switch_mode
      patch :switch_mode
      patch :conditions
    end

    resource :bulk_assignment, only: %i[new create] do
      post :preview
      get :revoke, action: :confirm_revoke
      delete :revoke
    end

    resources :resources, param: :model, only: %i[new create show destroy],
                          constraints: { model: %r{[^/]+} } do
      member do
        post :review
        patch :apply
        post :sync
        get :delete, action: :confirm_destroy
      end

      resources :fields, controller: 'resource_fields', param: :key, only: %i[show update],
                         constraints: { key: %r{[^/]+} } do
        member do
          post :acknowledge
          post :apply_recommendation
        end
      end
      resources :actions, controller: 'resource_actions', only: %i[new create show update destroy] do
        member do
          get :delete, action: :confirm_destroy
        end
      end
      resources :rules, controller: 'permission_set_rules', only: %i[new create edit update destroy] do
        collection do
          post :refresh
        end
        member do
          patch :toggle
          get :delete, action: :confirm_destroy
        end
      end
    end
  end

  resources :groups, controller: 'permission_set_groups', only: %i[index create show update destroy] do
    member do
      post :duplicate
      get :delete, action: :confirm_destroy
      post :add_set
      delete :remove_set
    end
    resources :members, controller: 'permission_set_group_users', only: %i[create destroy]
  end

  # JSON Admin API — routes are always drawn; access is guarded at runtime
  # by BaseController checking api_enabled + api_auth configuration.
  namespace :api, defaults: { format: :json } do
    # JSON only: `.json` or no extension. Any other extension
    # (`/permission_sets.xml`) matches no endpoint and reaches the catch-all
    # below: the JSON 404 envelope, never a JSON 200 under another format.
    constraints(format: /json/) do
      resource :stats, only: [:show], controller: 'dashboard'

      # The audit log is read-only over the API: no write route exists.
      resources :audit_events, only: %i[index show], param: :identifier

      # No new/edit: a JSON API has no forms. Without them `…/new` reads as
      # an identifier (404 unknown record) and `…/:identifier/edit` reaches
      # the catch-all (404), both in the envelope; through 0.14.1 they raised
      # AbstractController::ActionNotFound (Rails' own 404 page).
      resources :permission_sets, param: :identifier, except: %i[new edit] do
        member do
          post :clone
        end

        resources :resources, param: :identifier, except: %i[new edit] do
          member do
            post :generate_fields
          end
          resources :fields, param: :identifier, controller: 'resource_fields', except: %i[new edit]
          resources :actions, param: :identifier, controller: 'resource_actions', except: %i[new edit]
          resources :rules, param: :identifier, controller: 'permission_set_rules', except: %i[new edit]
        end

        resources :users, param: :identifier, controller: 'permission_set_users', only: %i[index create destroy] do
          collection do
            post :bulk
          end
        end
      end

      resources :permission_set_groups, param: :identifier, except: %i[new edit] do
        member do
          post :clone
        end
        resources :users, param: :identifier, controller: 'permission_set_group_users', only: %i[index create destroy]
      end
    end

    # Last: any other path or method under /api answers the JSON 404
    # envelope, not Rails' HTML page (Api::UnmatchedRoutesController).
    match '(*path)', to: 'unmatched_routes#show', via: %i[get post put patch delete], format: false
  end
end
