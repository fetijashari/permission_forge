# frozen_string_literal: true

require_relative 'admin_test_case'
require_relative '../cache/failing_store'

module PermissionForge
  module Html
    # The actions on a person's page that clear cached permissions — refresh,
    # erase, withdraw consent, remove all — say what happened: the cache store
    # may not confirm the removal, and the old entry is then still served.
    # The store here is a MemoryStore, so every message also says that the
    # other web workers and the job processes kept theirs (flash.cache_process_local:
    # the one Cache::Outcome, CacheConfirmation#cache_flash).
    class RefreshCacheFailureTest < AdminTestCase
      setup do
        @store = PermissionForge::Cache::FailingStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # The flash text for a people key, with the process-local scope appended.
      def people_flash(key, **)
        "#{I18n.t("permission_forge.flash.people.#{key}", **)} #{I18n.t('permission_forge.flash.cache_process_local')}"
      end

      test 'a refresh the store confirmed is announced as done' do
        post pf("/people/#{@ana.id}/refresh_cache")

        assert_redirected_to pf("/people/#{@ana.id}")
        assert_equal people_flash(:cache_refreshed, name: 'Ana Krasniqi'), flash[:notice]
        assert_nil flash[:alert]
      end

      test 'on a shared store the message carries no scope' do
        Dir.mktmpdir do |dir|
          PermissionForge.configuration.cache_backend = ActiveSupport::Cache::FileStore.new(dir)
          PermissionForge.configuration.reset_cache_store!

          post pf("/people/#{@ana.id}/refresh_cache")

          assert_equal I18n.t('permission_forge.flash.people.cache_refreshed', name: 'Ana Krasniqi'), flash[:notice]
        end
      end

      test 'a refresh the store did not confirm is announced as failed' do
        @store.down!

        post pf("/people/#{@ana.id}/refresh_cache")

        assert_redirected_to pf("/people/#{@ana.id}")
        assert_nil flash[:notice]
        assert_equal people_flash(:cache_refresh_failed, name: 'Ana Krasniqi'), flash[:alert]

        @store.up!
        follow_redirect!
        assert_select '.pf-toast--alert', text: /Could not refresh Ana Krasniqi's cached permissions/
        assert_no_missing_translations
      end

      test 'an erasure whose cache removal was confirmed is announced as done' do
        post pf("/people/#{@ana.id}/erasure"), params: { confirmation: 'Ana Krasniqi' }

        assert_redirected_to pf('/people')
        assert_equal people_flash(:erased, name: 'Ana Krasniqi'), flash[:notice]
        assert_nil flash[:alert]
      end

      # Inside a transaction of the host's the outcome is only known at its
      # commit (cache_cleared: nil): that is not a failure to announce.
      test 'an erasure made inside a transaction of the host is announced as done' do
        PermissionForge.configuration.snapshot_transactions = true

        ActiveRecord::Base.transaction do
          post pf("/people/#{@ana.id}/erasure"), params: { confirmation: 'Ana Krasniqi' }
        end

        assert_redirected_to pf('/people')
        assert_equal people_flash(:erased, name: 'Ana Krasniqi'), flash[:notice]
        assert_nil flash[:alert]
      end

      test 'an erasure whose cache removal the store did not confirm says so, and still erases' do
        @store.down!

        post pf("/people/#{@ana.id}/erasure"), params: { confirmation: 'Ana Krasniqi' }

        assert_redirected_to pf('/people')
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)
        assert_nil flash[:notice]
        assert_equal people_flash(:erased_cache_kept, name: 'Ana Krasniqi'), flash[:alert]

        @store.up!
        follow_redirect!
        assert_select '.pf-toast--alert', text: /did not confirm/
        assert_no_missing_translations
      end

      # --- the other actions that revoke (the reviewer's S6) --------------------------------

      test 'withdrawing consent says when the cached permissions could not be cleared' do
        gated = create_permission_set(name: 'Marketing', requires_session_flag: 'marketing_consent')
        create_permission_set_user(user: @ana, permission_set: gated)
        create_permission_set_user(user: @bo, permission_set: gated)

        post pf("/people/#{@bo.id}/consent"), params: { flag: 'marketing_consent' }
        assert_equal people_flash(:consent_withdrawn, count: 1, flag: 'marketing_consent'), flash[:notice]

        @store.down!
        reset! # a new session: the notice above is not carried along
        post pf("/people/#{@ana.id}/consent"), params: { flag: 'marketing_consent' }

        assert_not PermissionForge::PermissionSetUser.exists?(user: @ana, permission_set: gated)
        assert_nil flash[:notice]
        assert_equal people_flash(:consent_withdrawn_cache_kept, count: 1, flag: 'marketing_consent'), flash[:alert]
      end

      test 'withdrawing a consent the person holds nothing through stays a plain notice, also with the store down' do
        flags = PermissionForge.configuration.admin_session_flags
        PermissionForge.configuration.admin_session_flags = { 'marketing_consent' => 'Marketing' }
        @store.down!

        post pf("/people/#{@bo.id}/consent"), params: { flag: 'marketing_consent' }

        assert_equal people_flash(:consent_withdrawn, count: 0, flag: 'marketing_consent'), flash[:notice]
        assert_nil flash[:alert]
      ensure
        PermissionForge.configuration.admin_session_flags = flags
      end

      test 'removing all access says when the cached permissions could not be cleared' do
        create_permission_set_user(user: @bo, permission_set: @set)

        delete pf("/people/#{@bo.id}/remove_all")
        assert_equal people_flash(:removed_all, count: 1, name: 'Bo Berisha'), flash[:notice]

        @store.down!
        reset!
        delete pf("/people/#{@ana.id}/remove_all")

        assert_equal 0, PermissionForge::PermissionSetUser.where(user: @ana).count
        assert_nil flash[:notice]
        assert_equal people_flash(:removed_all_cache_kept, count: 1, name: 'Ana Krasniqi'), flash[:alert]

        @store.up!
        follow_redirect!
        assert_select '.pf-toast--alert', text: /did not confirm/
        assert_no_missing_translations
      end

      # --- a host override of invalidate_permissions (the reviewer's S4, S5) -----------------

      # A real host's override ends in the removal of an entry of its own, so
      # its value is whether that entry existed.
      test 'what the override returns does not decide the message' do
        own = ActiveSupport::Cache::MemoryStore.new
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          super(tenant_id: tenant_id)
          own.delete("own:#{id}")
        end

        post pf("/people/#{@ana.id}/refresh_cache")
        assert_equal people_flash(:cache_refreshed, name: 'Ana Krasniqi'), flash[:notice],
                     'nothing failed: the override answered false'

        own.write("own:#{@ana.id}", 1)
        @store.down!
        reset!
        post pf("/people/#{@ana.id}/refresh_cache")
        assert_equal people_flash(:cache_refresh_failed, name: 'Ana Krasniqi'), flash[:alert],
                     'the store is down: the override answered true'
        assert_nil flash[:notice]
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      test 'the failure messages exist in every bundled locale' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          %w[cache_refresh_failed erased_cache_kept].each do |key|
            message = I18n.t("permission_forge.flash.people.#{key}", name: 'Ana', locale: locale, raise: true)

            assert_includes message, 'Ana'
          end
          %w[consent_withdrawn_cache_kept removed_all_cache_kept].each do |key|
            [1, 2].each do |count|
              message = I18n.t("permission_forge.flash.people.#{key}", count: count, name: 'Ana', flag: 'consent', locale: locale, raise: true)

              assert_includes message, count.to_s
            end
          end
        end
      end
    end
  end
end
