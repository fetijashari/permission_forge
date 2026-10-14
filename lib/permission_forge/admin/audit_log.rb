# frozen_string_literal: true

require 'active_support/core_ext/numeric/time' # KNOWN_PEOPLE_WINDOW, read as this file loads

module PermissionForge
  module Admin
    # The admin's audit log: the events that match a filter, newest first,
    # one page at a time, with no cap on how far back the pages go.
    # Filtering is Audit::EventQuery's (the JSON API uses the same), so an
    # invalid value raises Audit::EventQuery::Invalid naming the parameter.
    #
    #   log = AuditLog.new(params)                       # every event
    #   log = AuditLog.new(params, scope: AuditLog.for_permission_set(set))
    #   log.page(params[:page])                          # => AuditLog::Page
    #   log.relation                                     # the whole result (exports)
    class AuditLog
      FILTERS = %w[from to event category actor_type actor_id subject_user_id permission_set correlation_id
                   record_type record_id record_uuid].freeze
      PER_PAGE = 50
      MAX_PAGE = 10_000_000
      KNOWN_PEOPLE = 500
      # known_people looks this far back (the occurred_at index serves it).
      KNOWN_PEOPLE_WINDOW = 90.days
      # Every view of the log writes one; left out of the default list and
      # the timelines so they do not bury the changes (exports keep them).
      VIEW_EVENT = 'audit.viewed'

      Page = Struct.new(:events, :total, :number, :per_page, keyword_init: true) do
        def pages = [(total + per_page - 1) / per_page, 1].max
        def first_index = total.zero? ? 0 : ((number - 1) * per_page) + 1
        def last_index = [number * per_page, total].min
        def previous? = number > 1
        def next? = number < pages
      end

      # Whether the audit table exists (the upgrade migration has run). The
      # log can be read while recording is switched off; without the table
      # there is nothing to read and every list is empty.
      def self.table?
        PermissionForge::AuditEvent.table_exists?
      rescue StandardError
        false
      end

      # Why the log is not recording, or nil when it records:
      #   :off            audit_events is false (with or without the table)
      #   :failing        audit_events is true, the table is missing and
      #                   audit_change_failure_strategy is :raise — every
      #                   permission change fails
      #   :missing_table  the table is missing otherwise — nothing is recorded
      def self.recording_problem(configuration = PermissionForge.configuration)
        return :off if configuration.audit_events == false
        return if table?
        return :failing if configuration.audit_events == true && configuration.audit_change_failure_strategy == :raise

        :missing_table
      end

      # The events of a Permission Set: its own, its resources', fields',
      # actions', rules' and assignments' (permission_set_id is filled on all).
      def self.for_permission_set(permission_set)
        return PermissionForge::AuditEvent.none unless table?

        PermissionForge::AuditEvent.where(permission_set_id: permission_set.id)
      end

      # The events about a person (their access) or by them (as the actor).
      def self.for_person(user_id)
        events = PermissionForge::AuditEvent
        return events.none unless table?

        events.where(subject_user_id: user_id.to_s).or(events.where(actor_type: 'user', actor_id: user_id.to_s))
      end

      # The filter parameters that are set, by name. Values are kept as
      # given (an array stays an array, so EventQuery can refuse it).
      #
      # @param params [ActionController::Parameters, Hash]
      # @return [ActiveSupport::HashWithIndifferentAccess]
      def self.filters(params)
        indifferent(params).slice(*FILTERS).reject { |_, value| value.blank? }
      end

      def self.indifferent(params)
        (params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h).with_indifferent_access
      end

      attr_reader :filters

      # @param params [ActionController::Parameters, Hash] see FILTERS; `views: '1'`
      #   keeps the views of the log in the list
      # @param scope [ActiveRecord::Relation] the events to filter
      # @param include_views [Boolean] keep the views of the log whatever the params say (exports)
      def initialize(params = {}, scope: PermissionForge::AuditEvent.all, include_views: false)
        @filters = self.class.filters(params)
        @views_asked = self.class.indifferent(params)[:views].to_s == '1'
        @include_views = include_views
        @scope = scope
      end

      # Views of the log are listed when asked for, when the filter names an
      # event or a category (whatever it names is shown), and in exports.
      def include_views?
        @include_views || @views_asked || @filters.key?('event') || @filters.key?('category')
      end

      # The filters plus the views toggle, for links that keep the page's state.
      def link_params
        @views_asked ? @filters.merge('views' => '1') : @filters
      end

      # @return [ActiveRecord::Relation] newest first
      # @raise [Audit::EventQuery::Invalid]
      def relation
        @relation ||= PermissionForge::Audit::EventQuery.call(AuditLogDays.localize(@filters), scope: base_scope)
      end

      def base_scope
        return @scope.none unless self.class.table?

        include_views? ? @scope : @scope.where.not(event: VIEW_EVENT)
      end
      private :base_scope

      # A page past the last one shows the last page.
      #
      # @param number [Object] the page parameter (1 when absent or not a number)
      # @return [Page]
      # @raise [Audit::EventQuery::Invalid]
      def page(number, per_page: PER_PAGE)
        total = relation.count
        current = self.class.page_number(number, total, per_page)
        events = relation.offset((current - 1) * per_page).limit(per_page).to_a
        Page.new(events: events, total: total, number: current, per_page: per_page)
      end

      # 1 for anything that is not a number; at most the last page.
      def self.page_number(number, total, per_page)
        return 1 unless number.to_s.match?(/\A\d{1,9}\z/)

        last = [(total + per_page - 1) / per_page, 1].max
        number.to_i.clamp(1, [last, MAX_PAGE].min)
      end

      # People the log names lately (KNOWN_PEOPLE_WINDOW), for the actor and
      # person filters' suggestions: [[id, label], ...]
      # by id. Actors keep the name the event recorded; people who are only
      # subjects are named from the user model when they still exist.
      #
      # @return [Array<Array(String, String)>]
      def self.known_people(limit: KNOWN_PEOPLE, configuration: PermissionForge.configuration)
        return [] unless table?

        actors = actor_labels(limit)
        people = actors.merge(subject_names(subject_ids(limit) - actors.keys, configuration))
        people.sort_by { |id, _| [id.to_s.rjust(20, '0'), id.to_s] }.first(limit)
      end

      # { actor id => the name the events recorded } of people acting lately.
      def self.actor_labels(limit)
        recent.where(actor_type: 'user').where.not(actor_id: nil).group(:actor_id).limit(limit).maximum(:actor_label)
      end

      def self.subject_ids(limit)
        recent.where.not(subject_user_id: nil).group(:subject_user_id).limit(limit).count.keys
      end

      def self.recent
        PermissionForge::AuditEvent.where(occurred_at: KNOWN_PEOPLE_WINDOW.ago..)
      end

      # { id => label (nil when the person is gone) } for every id.
      def self.subject_names(ids, configuration)
        return {} if ids.empty?

        found = configuration.user_model.where(id: ids).to_h { |user| [user.id.to_s, PersonLabel.new(user).name] }
        ids.index_with { |id| found[id.to_s] }
      rescue StandardError
        ids.index_with(nil)
      end
      private_class_method :actor_labels, :subject_ids, :subject_names, :recent

      # Every catalogued event name, by category (the event filter).
      # @return [Hash{String => Array<String>}]
      def self.event_names_by_category
        PermissionForge::Audit::EventCatalog.entries.values.group_by(&:category)
                                            .transform_values { |entries| entries.map(&:name).sort }
                                            .sort_by { |category, _| PermissionForge::AuditEvent::CATEGORIES.index(category) || 99 }
                                            .to_h
      end
    end
  end
end
