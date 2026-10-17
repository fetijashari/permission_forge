# frozen_string_literal: true

module PermissionForge
  module Admin
    # Resolves pasted emails/names (one per line or comma-separated) to people
    # for bulk assignment. Exact, case-insensitive matches only — a near miss
    # is reported as "not found" rather than guessed. A column the user model
    # encrypts (PermissionForge::EncryptedAttributes) holds ciphertext: a
    # deterministically encrypted one matches the pasted value exactly
    # (`where(email: value)` encrypts it), any other is not matched. Only people within
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
        return exact(email_columns, token) if token.include?('@')

        exact(name_column, token) || first_last_match(token)
      end

      # The first listed person whose value in any of `columns` equals the token.
      def exact(columns, token)
        scopes = Array(columns).filter_map { |column| equal_to(column, token) }
        first_listed(scopes.reduce(:or)) if scopes.any?
      end

      # The people whose `column` equals the token, whatever its case; for a
      # deterministically encrypted column the value as pasted or lower-cased
      # (the attribute type encrypts it); nil for a column SQL cannot compare
      # (encrypted otherwise).
      def equal_to(column, token)
        if PermissionForge::EncryptedAttributes.encrypted?(model, column)
          return unless PermissionForge::EncryptedAttributes.deterministic?(model, column)

          return model.where(column => [token, token.downcase].uniq)
        end
        model.where(model.arel_table[column].lower.eq(token.downcase))
      end

      # The first match that config.user_list holds.
      def first_listed(matches)
        directory.find_all(matches.limit(CANDIDATES_PER_TOKEN).ids).first
      end

      def directory
        @directory ||= PeopleDirectory.new(configuration: @configuration)
      end

      # Every email column the user table has (`email`, `email_address`).
      def email_columns
        PermissionForge::SchemaRead.columns_among(model, PersonLabel::EMAIL_ATTRIBUTES.map(&:to_s))
      end

      # "Ana Krasniqi" against separate first/last name columns.
      def first_last_match(token)
        first, last = token.split(/\s+/, 2)
        pair = first_last_columns
        return nil unless pair && last

        scopes = [equal_to(pair.first, first), equal_to(pair.last, last)]
        first_listed(scopes.first.merge(scopes.last)) if scopes.all?
      end

      def first_last_columns
        FIRST_LAST_COLUMNS.find { |cols| PermissionForge::SchemaRead.columns_among(model, cols).size == cols.size }
      end

      def name_column
        PermissionForge::SchemaRead.columns_among(model, %w[name full_name display_name]).first
      end

      def picked(ids)
        directory.find_all(ids)
      end
    end
  end
end
