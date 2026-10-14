# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Covers ApplicationController#available_locale? — the guard that decides
  # whether a ?locale= param may be stored in the session.
  class ApplicationControllerLocaleTest < ActionDispatch::IntegrationTest
    teardown do
      PermissionForge.configuration.available_locales = nil
    end

    test 'stores the locale in the session when it is bundled' do
      get '/permission_forge/', params: { locale: 'sq' }

      assert_response :ok
      assert_equal 'sq', session[:permission_forge_locale]
    end

    test 'ignores an unknown locale' do
      get '/permission_forge/', params: { locale: 'zz' }

      assert_response :ok
      assert_nil session[:permission_forge_locale]
    end

    test 'honors a config.available_locales restriction' do
      PermissionForge.configuration.available_locales = [:en]

      get '/permission_forge/', params: { locale: 'sq' }

      assert_response :ok
      assert_nil session[:permission_forge_locale]
    end
  end
end
