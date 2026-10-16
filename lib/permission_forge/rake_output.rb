# frozen_string_literal: true

module PermissionForge
  # What the gem's rake tasks print: one presenter for a run's result, so the
  # terminal says what the summary audit event records — one line per key,
  # named — the cache outcome (Cache::Outcome: confirmed, scope, unconfirmed)
  # where the result carries one, and people named as the admin names them
  # (Admin::PersonLabel), never "User 2". Rake output stays English.
  #
  #   PermissionForge::RakeOutput.report("Erasure complete for #{RakeOutput.person(user)}:", result)
  #   PermissionForge::RakeOutput.people(ids)   # => { "12" => "Rae Rake (id 12)" }
  #
  # @api private
  module RakeOutput
    # The label of each key a service answers or an event records. The event
    # key and the result key of one fact share a label (set_names /
    # permission_sets), so a reader finds every event key in the output. A
    # key without one is printed as its words.
    LABELS = {
      'assignments_removed' => 'Permission set assignments removed',
      'assignments_count' => 'Permission set assignments',
      'group_assignments_removed' => 'Group memberships removed',
      'group_assignments_count' => 'Group memberships',
      'assignments_remaining_elsewhere' => 'Assignments remaining in other tenants',
      'group_assignments_remaining_elsewhere' => 'Group memberships remaining in other tenants',
      'permission_sets' => 'Permission sets', 'set_names' => 'Permission sets',
      'groups' => 'Groups', 'group_names' => 'Groups',
      'actor_labels_cleared' => 'Audit log name labels cleared as actor',
      'record_labels_cleared' => 'Audit log name labels cleared as subject',
      'actor_labels_to_clear' => 'Audit log name labels to clear as actor',
      'record_labels_to_clear' => 'Audit log name labels to clear as subject',
      'events_scrubbed' => 'Audit events with a name label cleared',
      'callback_invoked' => 'on_erasure callback',
      'removed' => 'Expired assignments removed', 'expired_count' => 'Expired assignments',
      'invalidated' => 'People whose cached permissions were invalidated',
      'affected_user_ids' => 'People affected',
      'strategy' => 'Strategy', 'users' => 'User visits invalidated', 'tenants' => 'Tenants',
      'purged' => 'Audit events deleted', 'count' => 'Audit events deleted', 'cutoff' => 'Deleted when older than',
      'period' => 'Retention period', 'period_seconds' => 'Retention period',
      'retention_configured' => 'Retention configured',
      'cache_confirmed' => 'Cached permissions removed', 'process_local' => 'Cache scope',
      'unconfirmed' => 'People the cache store did not confirm'
    }.freeze

    # Keys of a result the cache lines say already.
    SILENT = %w[cache_cleared].freeze
    # Keys printed as people.
    PEOPLE_KEYS = %w[affected_user_ids].freeze
    PEOPLE_SHOWN = 50
    STRATEGIES = { 'pattern' => 'pattern (the store removed the keys by pattern; users not counted)',
                   'enumerated' => 'enumerated (every user invalidated, in slices)' }.freeze
    CONFIRMED = { true => 'yes (the cache store confirmed it)',
                  false => 'NO — the cache store did not confirm it; the old permissions may be served until cache_ttl',
                  nil => 'not known yet — the invalidation follows the commit of the surrounding transaction' }.freeze
    CALLBACK = { true => 'ran', false => 'none configured', nil => 'runs when the surrounding transaction commits' }.freeze
    # The "Cache scope" line of a process-local store (Cache::Outcome#process_local?) and of a shared one.
    PROCESS_LOCAL_NOTE = 'this process only — an in-memory store (cache_backend :memory, or :memory_store) lives in each ' \
                         'process, so the web and job processes keep their cached permissions until they restart or the ' \
                         'entries expire (cache_ttl). Invalidate the users from inside those processes, or restart them.'
    SHARED_NOTE = 'a shared store — every process sees the change.'
    NOT_IN_LIST = 'not in the people list'

    module_function

    # Prints the title and one line per key of `data` (a service's result,
    # symbol or string keys); `cache:` (a Cache::Outcome or its Hash) prints
    # as the three cache lines.
    #
    # @param title [String]
    # @param data [Hash]
    # @param io [IO]
    # @return [void]
    def report(title, data, io: $stdout)
      io.puts title
      lines(data).each { |line| io.puts "  #{line}" }
    end

    # @return [Array<String>] "Label: value" per key
    def lines(data)
      data = data.transform_keys(&:to_s)
      data.except(*SILENT).flat_map do |key, value|
        key == 'cache' ? cache_lines(value, data) : ["#{label(key)}: #{format_value(key, value)}"]
      end
    end

    # @param key [String, Symbol]
    # @return [String]
    def label(key)
      LABELS.fetch(key.to_s) { key.to_s.tr('_', ' ').then { |words| words[0].to_s.upcase + words[1..].to_s } }
    end

    # @param user [Object, String, Integer] a host user, or an id
    # @return [String] "Rae Rake (id 12)"
    def person(user)
      return people([user]).values.first if user.is_a?(String) || user.is_a?(Integer)

      "#{person_name(user)} (id #{user.id})"
    end

    # The people `ids` name, within config.user_list_resolver
    # (Admin::PeopleDirectory, as the admin looks people up).
    #
    # @param ids [Array]
    # @return [Hash{String => String}] id → "Name (id N)", or "id N (not in the people list)"
    def people(ids)
      found = Admin::PeopleDirectory.new.find_all(ids).index_by { |user| user.id.to_s }
      ids.map(&:to_s).uniq.to_h do |id|
        user = found[id]
        [id, user ? person(user) : "id #{id} (#{NOT_IN_LIST})"]
      end
    end

    def person_name(user)
      label = Admin::PersonLabel.new(user)
      name = label.name
      name == I18n.t('permission_forge.shared.user_fallback', id: user.id) ? 'no name or email on record' : name
    end

    def cache_lines(value, data)
      outcome = Cache::Outcome.wrap(value)
      keys = %w[cache_confirmed process_local]
      keys << 'unconfirmed' unless data.key?('unconfirmed')
      outcome.event_data.slice(*keys).map { |key, item| "#{label(key)}: #{format_value(key, item)}" }
    end

    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength -- one table of value shapes
    def format_value(key, value)
      case key
      when 'cache_confirmed' then CONFIRMED.fetch(value)
      when 'process_local' then value == true ? PROCESS_LOCAL_NOTE : SHARED_NOTE
      when 'callback_invoked' then CALLBACK.fetch(value)
      when 'strategy' then STRATEGIES.fetch(value.to_s, value.to_s)
      when 'users' then value.nil? ? 'not counted (removed by key pattern)' : value.to_s
      when 'period', 'period_seconds' then "#{value} seconds (#{(value.to_i / 86_400.0).round(1)} days)"
      when *PEOPLE_KEYS then people_list(Array(value))
      else plain(value)
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

    def people_list(ids)
      return 'none' if ids.empty?

      names = people(ids.first(PEOPLE_SHOWN)).values
      names << "and #{ids.size - PEOPLE_SHOWN} more" if ids.size > PEOPLE_SHOWN
      "#{ids.size} — #{names.join(', ')}"
    end

    def plain(value)
      case value
      when true then 'yes'
      when false then 'no'
      when nil then 'not known'
      when Array then value.empty? ? 'none' : value.join(', ')
      when Time, DateTime, ActiveSupport::TimeWithZone then value.iso8601
      else value.to_s
      end
    end
  end
end
