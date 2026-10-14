# frozen_string_literal: true

module PermissionForge
  module Admin
    # Resolves pasted emails/names (one per line or comma-separated) to people
    # for bulk assignment. Exact, case-insensitive matches only — a near miss
    # is reported as "not found" rather than guessed. Only people within
    # config.user_list_resolver match (PeopleDirectory#find_all): anyone else
    # is "not found" too.
    class BulkPeopleMatcher
      FIRST_LAST_COLUMNS = [%w[first_name last_name], %w[firstname lastname]].freeze
      # Same-named people considered per pasted line before the resolver
      # narrows them.
      CANDIDATES_PER_TOKEN = 20

      Result = Struct.new(:to_assign, :already, :not_found, keyword_init: true)

      # @param directory [PeopleDirectory, nil] share the request's directory,
      #   so an array-returning resolver is evaluated once per request
      def initialize(configuration: PermissionForge.configuration, directory: nil)
        @configuration = configuration
        @directory = directory
      end

      # @param text [String] pasted identifiers
      # @param user_ids [Array] people picked with checkboxes
      # @param permission_set [PermissionSet]
      def call(text:, user_ids:, permission_set:)
        found, not_found = resolve(tokens(text))
        picked(user_ids).each { |user| found[user.id] = user }

        already, to_assign = partition_assigned(found.values, permission_set)
        Result.new(to_assign: to_assign, already: already, not_found: not_found)
      end

      private

      # [already assigned, not yet assigned]
      def partition_assigned(users, permission_set)
        assigned = permission_set.permission_set_users.where(user_id: users.map(&:id)).pluck(:user_id)
        users.partition { |user| assigned.include?(user.id) }
      end

      def tokens(text)
        PeopleDirectory.search_text(text).split(/[\n,;]+/).map(&:strip).reject(&:empty?).uniq
      end

      # [{ id => user } for matched tokens, unmatched tokens]
      def resolve(tokens)
        found = {}
        not_found = tokens.reject do |token|
          user = lookup(token)
          found[user.id] = user if user
        end
        [found, not_found]
      end

      def model
        @configuration.user_model
      end

      def lookup(token)
        needle = token.downcase
        return exact(column_if_present('email'), needle) if token.include?('@')

        exact(name_column, needle) || first_last_match(needle)
      end

      def exact(column, needle)
        column && first_listed(model.where(model.arel_table[column].lower.eq(needle)))
      end

      # The first match that config.user_list holds.
      def first_listed(matches)
        directory.find_all(matches.limit(CANDIDATES_PER_TOKEN).ids).first
      end

      def directory
        @directory ||= PeopleDirectory.new(configuration: @configuration)
      end

      def column_if_present(column)
        column if model.column_names.include?(column)
      end

      # "Ana Krasniqi" against separate first/last name columns.
      def first_last_match(needle)
        first, last = needle.split(/\s+/, 2)
        pair = first_last_columns
        return nil unless pair && last

        table = model.arel_table
        first_listed(model.where(table[pair.first].lower.eq(first).and(table[pair.last].lower.eq(last))))
      end

      def first_last_columns
        FIRST_LAST_COLUMNS.find { |cols| (cols - model.column_names).empty? }
      end

      def name_column
        (%w[name full_name display_name] & model.column_names).first
      end

      def picked(ids)
        directory.find_all(ids)
      end
    end
  end
end
