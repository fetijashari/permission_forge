# frozen_string_literal: true

require_relative '../html/admin_test_case'

module PermissionForge
  module Audit
    # G3a. Every event of a cache-touching operation (EventCatalog entries
    # registered with `cache: true`) carries one Cache::Outcome: whether the
    # store confirmed the work (`cache_confirmed`), how many users it did not
    # confirm (`unconfirmed`) and whether the store lives in this process
    # only (`process_local`, Cache::Base#process_local?). The audit log's
    # sentence then ends with the one process-local suffix
    # (audit_log.cache_scope.process_local) in every bundled locale; on a
    # shared store it does not.
    #
    # PRODUCERS runs each flagged event's operation on the suite's store. An
    # event flagged without a producer, or a producer for an unflagged event,
    # fails: a new cache-touching operation is covered here or not at all.
    class CacheScopeEventsTest < Html::AdminTestCase
      # Each block runs as the test (instance_exec): the fixture helpers and
      # `person` are its own.
      PRODUCERS = {
        'erasure.performed' => -> { PermissionForge::Services::DataSubjectErasure.call(user: person, actor: 'dpo') },
        'consent.withdrawn' => lambda do
          gated = create_permission_set(name: "Marketing #{SecureRandom.hex(2)}", requires_session_flag: 'marketing')
          create_permission_set_user(user: person, permission_set: gated)
          PermissionForge::Services::ConsentWithdrawalHandler.call(user: person, consent_flag: 'marketing', actor: 'dpo')
        end,
        'cleanup.expired_assignments' => lambda do
          expiring = create_permission_set(name: "Temp #{SecureRandom.hex(2)}")
          create_permission_set_user(user: person, permission_set: expiring, expires_at: 1.day.from_now)
          travel_to(2.days.from_now) { PermissionForge::Services::ExpiredAssignmentCleaner.call(actor: 'ops') }
        end,
        'cache.cleared' => -> { PermissionForge::Services::PermissionCacheClearer.call(actor: 'ops') }
      }.freeze

      SUFFIX_KEY = 'permission_forge.audit_log.cache_scope.process_local'

      attr_reader :person

      setup do
        @person = create_user(name: 'Pia Process', email: 'pia@acme.test')
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      def self.flagged
        PermissionForge::Audit::EventCatalog.entries.values.select(&:cache?).map(&:name).sort
      end

      # The flagged events PRODUCERS does not cover, and the producers of
      # events that are not flagged.
      def self.uncovered(flagged = self.flagged)
        { without_producer: flagged - PRODUCERS.keys, not_flagged: PRODUCERS.keys - flagged }
      end

      def newest(event)
        PermissionForge::AuditEvent.unscoped.where(event: event).order(:id).last
      end

      def produce(event)
        before = PermissionForge::AuditEvent.unscoped.maximum(:id) || 0
        instance_exec(&PRODUCERS.fetch(event))
        produced = newest(event)
        assert produced && produced.id > before, "#{event}: the producer recorded no such event"
        produced
      end

      def sentence_of(event, locale:)
        get pf("/audit/#{event.uuid}"), params: { locale: locale }
        assert_response :success
        css_select('.pf-audit-event__sentence').map { |node| node.text.squish }.join(' ')
      end

      test 'the flagged events and PRODUCERS name the same operations' do
        assert_equal %w[cache.cleared cleanup.expired_assignments consent.withdrawn erasure.performed], self.class.flagged
        assert_equal({ without_producer: [], not_flagged: [] }, self.class.uncovered)
      end

      test 'negative fixture: a flagged event without a producer is reported' do
        PermissionForge::Audit::EventCatalog.register('host.cache_touched', category: 'system', cache: true)

        assert_equal ['host.cache_touched'], self.class.uncovered[:without_producer]
      ensure
        PermissionForge::Audit::EventCatalog.unregister('host.cache_touched')
      end

      PRODUCERS.each_key do |name|
        test "#{name} on the suite's memory store says process-local, with the outcome keys, in every locale" do
          event = produce(name)

          assert_equal true, event.data['process_local'], event.data.inspect
          assert event.data.key?('cache_confirmed'), "#{name}: no cache_confirmed in #{event.data.keys}"
          assert event.data.key?('unconfirmed'), "#{name}: no unconfirmed in #{event.data.keys}"

          PermissionForge::BUNDLED_LOCALES.each do |locale|
            suffix = I18n.t(SUFFIX_KEY, locale: locale, raise: true)
            assert_includes sentence_of(event, locale: locale), suffix, "#{name} in #{locale}"
          end
        end

        test "#{name} on a shared store says process_local false and reads without the suffix" do
          Dir.mktmpdir do |dir|
            PermissionForge.configuration.cache_backend = ActiveSupport::Cache::FileStore.new(dir)
            PermissionForge.configuration.reset_cache_store!

            event = produce(name)

            assert_equal false, event.data['process_local'], event.data.inspect
            assert_not_includes sentence_of(event, locale: :en), I18n.t(SUFFIX_KEY, locale: :en)
          end
        end
      end

      test 'the suffix is one sentence per locale, with no interpolation' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          suffix = I18n.t(SUFFIX_KEY, locale: locale, raise: true)
          assert_no_match(/%\{/, suffix)
          assert suffix.end_with?('.'), "#{locale}: #{suffix.inspect}"
        end
      end
    end
  end
end
