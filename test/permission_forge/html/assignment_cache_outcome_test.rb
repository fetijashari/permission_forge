# frozen_string_literal: true

require_relative 'admin_test_case'
require_relative '../cache/failing_store'

module PermissionForge
  module Html
    # One person's assignment changes say what the cache store confirmed, as
    # a bulk revoke of the same person does (R2 review, P1-2): with the
    # store down the toast is an alert saying the old permissions may stay
    # in use (flash.cache_not_confirmed); confirmed, the usual notice. The
    # store is a MemoryStore here, so every message ends with
    # flash.cache_process_local (CacheConfirmation#cache_flash_text).
    class AssignmentCacheOutcomeTest < AdminTestCase
      setup do
        @store = PermissionForge::Cache::FailingStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
        @other_set = create_permission_set(name: 'Support')
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      def confirmed(key, **)
        "#{I18n.t("permission_forge.flash.#{key}", **)} #{I18n.t('permission_forge.flash.cache_process_local')}"
      end

      def unconfirmed(key, **)
        [I18n.t("permission_forge.flash.#{key}", **), I18n.t('permission_forge.flash.cache_not_confirmed'),
         I18n.t('permission_forge.flash.cache_process_local')].join(' ')
      end

      test 'removing one assignment with the store down is an alert, and still removes it' do
        @store.down!

        delete pf("/assignments/#{@assignment.id}")

        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)
        assert_nil flash[:notice]
        assert_equal unconfirmed('assignments.removed', name: 'Ana Krasniqi', set: 'Sales rep'), flash[:alert]
      end

      test 'removing one assignment the store confirmed is the notice' do
        delete pf("/assignments/#{@assignment.id}")

        assert_equal confirmed('assignments.removed', name: 'Ana Krasniqi', set: 'Sales rep'), flash[:notice]
        assert_nil flash[:alert]
      end

      test 'assigning, changing the end, keeping, restoring and undoing with the store down are alerts' do
        @store.down!
        requests = {
          create: -> { post pf('/assignments'), params: { user_id: @bo.id, set_ids: [@other_set.id], expiry: 'never' } },
          update: -> { patch pf("/assignments/#{@assignment.id}"), params: { expiry: 'extend30' } },
          keep: -> { post pf("/assignments/#{@assignment.id}/keep") },
          undo: lambda {
            assignment = create_permission_set_user(user: @bo, permission_set: @set)
            post pf('/assignments/undo'), params: { ids: [assignment.id] }
          },
          restore: lambda {
            @assignment.destroy!
            post pf('/assignments/restore'), params: { permission_set_id: @set.id, user_id: @ana.id }
          }
        }
        requests.each do |name, request|
          reset!
          request.call

          assert_nil flash[:notice], name
          assert_includes flash[:alert].to_s, I18n.t('permission_forge.flash.cache_not_confirmed'), name
        end
      end

      test 'saving batched edits with the store down is an alert' do
        @store.down!

        patch pf("/permission_sets/#{@set.id}/apply"), params: { pf: { set: { description: 'Changed' } } }

        assert_equal 'Changed', @set.reload.description
        assert_nil flash[:notice]
        assert_includes flash[:alert].to_s, I18n.t('permission_forge.flash.cache_not_confirmed')
      end

      test 'the sentence exists in every bundled locale' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          assert I18n.t('permission_forge.flash.cache_not_confirmed', locale: locale, raise: true).present?
        end
      end
    end
  end
end
