# frozen_string_literal: true

module PermissionForge
  module Admin
    # The Permission Sets list: the sets a filter and a search select, how
    # many sets each filter has, and what the list says about each set
    # (SetSummaries) and who holds it. The search matches a set's name, its
    # description, or the stored name of one of its active Resources.
    class PermissionSetList
      FILTERS = %w[all granting muting conditional off].freeze

      # Filter => predicate on a set ('all' matches everything).
      MATCHERS = {
        'all' => ->(_set) { true },
        'granting' => ->(set) { !set.is_muting },
        'muting' => lambda(&:is_muting),
        'conditional' => lambda(&:conditional?),
        'off' => ->(set) { !set.is_active }
      }.freeze

      attr_reader :query, :filter

      # @param query [String] the search, as typed
      # @param filter [String] one of FILTERS (anything else: 'all')
      def initialize(query:, filter:)
        @query = query.to_s
        @filter = FILTERS.include?(filter) ? filter : 'all'
        @all = PermissionForge::PermissionSet.includes(:permission_set_group).order(:name).to_a
        @summaries = SetSummaries.call(@all)
      end

      # @return [Array<PermissionSet>] the sets the filter and the search select
      def sets = @all.select { |set| MATCHERS.fetch(filter).call(set) && found?(set) }

      def total = @all.size
      def counts = FILTERS.index_with { |key| @all.count(&MATCHERS.fetch(key)) }

      # @return [SetSummaries::Summary]
      def summary(set) = @summaries.fetch(set.id)

      # The set's active Resources whose name the search matches (none without a search).
      def matching(set) = query.empty? ? [] : summary(set).matching(needle)

      # @return [Hash{Integer => Integer}] people holding each set (active assignments)
      def people_counts
        @people_counts ||= PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
      end

      # @return [Integer] the application's models (the bar of a set's Resources)
      def model_count = @model_count ||= ModelCatalog.new(verify: false).models.size

      private

      def needle = query.downcase

      def found?(set)
        query.empty? || [set.name, set.description].compact.any? { |text| text.downcase.include?(needle) } ||
          matching(set).any?
      end
    end
  end
end
