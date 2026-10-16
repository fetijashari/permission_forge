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
      # `person` are its own. Each returns the service's result.
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
          result = nil
          travel_to(2.days.from_now) { result = PermissionForge::Services::ExpiredAssignmentCleaner.call(actor: 'ops') }
          result
        end,
        'cache.cleared' => -> { PermissionForge::Services::PermissionCacheClearer.call(actor: 'ops') }
      }.freeze

      # The suffix by where the operation ran (Cache::Outcome#in_request):
      # a process of its own (a runner, a rake task, the test) or a request.
      SUFFIX_KEYS = { false => 'permission_forge.audit_log.cache_scope.own_process',
                      true => 'permission_forge.audit_log.cache_scope.server_process' }.freeze
      OUTCOME_KEYS = %w[cache_confirmed process_local in_request unconfirmed].freeze

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

      # The newest event of the name in the ambient tenant (a tenant-less
      # summary — cache.cleared's totals — is not on the tenant's log).
      def newest(event)
        PermissionForge::AuditEvent.where(event: event).order(:id).last
      end

      # @return [Array(AuditEvent, Hash)] the event produced and the service's result
      def produce(event)
        before = PermissionForge::AuditEvent.unscoped.maximum(:id) || 0
        result = instance_exec(&PRODUCERS.fetch(event))
        produced = newest(event)
        assert produced && produced.id > before, "#{event}: the producer recorded no such event"
        assert_kind_of Hash, result[:cache], "#{event}: the service answers no cache: outcome (#{result.inspect})"
        [produced, result]
      end

      # The detail page's heading is the sentence.
      def sentence_of(event, locale:)
        get pf("/audit/#{event.uuid}"), params: { locale: locale }
        assert_response :success
        css_select('h1').map { |node| node.text.squish }.join(' ')
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
        # Run from the test (a process of its own, like a runner): the event
        # and the result say process-local, and the sentence says every web
        # and job process kept theirs.
        test "#{name} on the suite's memory store says process-local in the event and the result, in every locale" do
          event, result = produce(name)

          OUTCOME_KEYS.each { |key| assert event.data.key?(key), "#{name}: no #{key} in #{event.data.keys}" }
          assert_equal true, event.data['process_local'], event.data.inspect
          assert_equal false, event.data['in_request'], event.data.inspect
          assert_equal true, result[:cache][:process_local], "the result's cache outcome: #{result[:cache].inspect}"
          assert_equal false, result[:cache][:in_request]

          PermissionForge::BUNDLED_LOCALES.each do |locale|
            suffix = I18n.t(SUFFIX_KEYS.fetch(false), locale: locale, raise: true)
            assert_includes sentence_of(event, locale: locale), suffix, "#{name} in #{locale}"
          end
        end

        # Run inside a request the admin served (the audit context says so):
        # this server process did see it, so the sentence names the other
        # web workers and the job processes, never "the web processes".
        test "#{name} from an admin request says process-local for the other processes only" do
          event, result = PermissionForge::Audit::Context.with(source: 'admin_ui') { produce(name) }

          assert_equal true, event.data['process_local']
          assert_equal true, event.data['in_request'], event.data.inspect
          assert_equal true, result[:cache][:in_request]
          sentence = sentence_of(event, locale: :en)
          assert_includes sentence, I18n.t(SUFFIX_KEYS.fetch(true), locale: :en)
          assert_not_includes sentence, 'the web and job processes kept theirs'
        end

        test "#{name} on a shared store says process_local false and reads without a suffix" do
          Dir.mktmpdir do |dir|
            PermissionForge.configuration.cache_backend = ActiveSupport::Cache::FileStore.new(dir)
            PermissionForge.configuration.reset_cache_store!

            event, result = produce(name)

            assert_equal false, event.data['process_local'], event.data.inspect
            assert_equal false, result[:cache][:process_local]
            sentence = sentence_of(event, locale: :en)
            SUFFIX_KEYS.each_value { |key| assert_not_includes sentence, I18n.t(key, locale: :en) }
          end
        end
      end

      test 'each suffix is one sentence per locale, with no interpolation, and the two differ' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          suffixes = SUFFIX_KEYS.values.map { |key| I18n.t(key, locale: locale, raise: true) }
          suffixes.each do |suffix|
            assert_no_match(/%\{/, suffix)
            assert suffix.end_with?('.'), "#{locale}: #{suffix.inspect}"
          end
          assert_equal 2, suffixes.uniq.size, locale
        end
      end
    end
  end
end
