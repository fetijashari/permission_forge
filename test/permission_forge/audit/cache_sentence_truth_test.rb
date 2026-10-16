# frozen_string_literal: true

require_relative '../html/admin_test_case'
require_relative 'runtime_support'
require_relative '../../support/boot_test_helpers'

module PermissionForge
  module Audit
    # The audit log's sentence about cache work says what the store said
    # (R2 review): an unconfirmed clear or invalidation is never "cleared"
    # (P1-3), and an operation inside a host's web request is a server
    # process's, never "the web processes kept theirs" said from a web
    # process (P1-4). Where it ran is decided in one place
    # (Cache::Report#in_request?: an admin/API request, or any code of a
    # server process, Warnings.server_process?).
    class CacheSentenceTruthTest < Html::AdminTestCase
      include BootTestHelpers
      include MethodStubs
      include RuntimeSupport

      def sentences(**params)
        get pf('/audit'), params: params
        assert_response :success
        css_select('.pf-audit-event__sentence').map { |node| node.text.squish }
      end

      def store_event(name, data, source: 'rake')
        PermissionForge::AuditEvent.store!(uuid: SecureRandom.uuid, event: name, category: 'system', actor_type: 'system',
                                           actor_label: 'Ops on-call', source: source, occurred_at: Time.current,
                                           subject_user_id: @ana.id.to_s, record_type: 'User', record_id: @ana.id.to_s,
                                           data: data)
      end

      # --- P1-3 ----------------------------------------------------------------------

      test 'a clear of every cache the store did not confirm is not told as cleared' do
        store_event('cache.cleared', { 'operation' => 'cache_clear', 'cache_confirmed' => false, 'process_local' => false })

        listed = sentences(event: 'cache.cleared')

        assert_includes listed, I18n.t('permission_forge.audit_log.sentence_variants.cache_cleared_unconfirmed', actor: 'Ops on-call')
        assert(listed.none? { |text| text.include?('cleared the cached permissions of every user') }, listed.inspect)
      end

      test 'an invalidation the store did not confirm is not told as cleared' do
        store_event('permissions.invalidated', { 'confirmed' => false, 'process_local' => false })

        listed = sentences(event: 'permissions.invalidated')

        assert_includes listed, I18n.t('permission_forge.audit_log.sentence_variants.permissions_invalidated_unconfirmed',
                                       person: 'Ana Krasniqi')
      end

      test 'the scope suffix of an unconfirmed operation on a per-process store does not say cleared either' do
        store_event('permissions.invalidated', { 'confirmed' => false, 'process_local' => true, 'in_request' => true })
        store_event('cache.cleared', { 'cache_confirmed' => false, 'process_local' => true, 'in_request' => false })

        listed = sentences(event: %w[permissions.invalidated cache.cleared])

        assert_equal 2, listed.size, listed.inspect
        assert(listed.all? { |text| text.end_with?(I18n.t('permission_forge.audit_log.cache_scope.unconfirmed')) }, listed.inspect)
        assert(listed.none? { |text| text.include?('were cleared') }, listed.inspect)
      end

      test 'every variant and suffix exists in every bundled locale' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          %w[sentence_variants.cache_cleared_unconfirmed sentence_variants.permissions_invalidated_unconfirmed
             cache_scope.unconfirmed cache_scope.own_process cache_scope.server_process].each do |key|
            assert I18n.t("permission_forge.audit_log.#{key}", actor: 'A', person: 'P', locale: locale, raise: true).present?
          end
        end
      end

      # --- P1-4 ----------------------------------------------------------------------

      test 'the own-process suffix never names the web processes' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          text = I18n.t('permission_forge.audit_log.cache_scope.own_process', locale: locale)

          assert_no_match(/web|uebit|веб/i, text, locale)
        end
      end

      test 'any code of a server process counts as in a request, whatever its audit source' do
        PermissionForge::Audit::Context.with(source: nil) do
          assert_not PermissionForge::Cache::Report.new.in_request?
          with_singleton_method(PermissionForge::Warnings, :server_process?, -> { true }) do
            assert PermissionForge::Cache::Report.new.in_request?
          end
        end
      end

      test 'an invalidation inside a host controller request of a server process records in_request' do
        store_runtime(:cache)
        ana = @ana
        original = PfAuditProbesController.instance_method(:index)
        replace_method(PfAuditProbesController, :index) do
          ana.invalidate_permissions
          head :ok
        end

        with_singleton_method(PermissionForge::Warnings, :server_process?, -> { true }) do
          get '/pf_audit_probe/customers'
        end

        assert_response :ok
        event = PermissionForge::AuditEvent.where(event: 'permissions.invalidated').order(:id).last
        assert_equal true, event.data['in_request'], event.data.inspect
        assert(sentences(event: 'permissions.invalidated').all? do |text|
          text.end_with?(I18n.t('permission_forge.audit_log.cache_scope.server_process'))
        end)
      ensure
        replace_method(PfAuditProbesController, :index, original) if original
      end
    end
  end
end
