# frozen_string_literal: true

module PermissionForge
  module Admin
    # Uniform filter / search / paging over the people list, whether
    # config.user_list returns an ActiveRecord relation (filtered in SQL) or an
    # array (filtered in Ruby). Each operation returns a new candidates object.
    module PeopleCandidates
      def self.wrap(list, configuration:)
        list.respond_to?(:where) ? Relation.new(list) : List.new(list, configuration)
      end

      # SQL-backed: searches whichever of the usual name/email columns exist.
      class Relation
        # Common person columns; only those the user table has are searched.
        SEARCH_COLUMNS = (%w[name] + PersonLabel::EMAIL_ATTRIBUTES.map(&:to_s) +
                          %w[full_name display_name first_name last_name firstname lastname username login]).freeze
        # A query of digits also matches the id — up to a bigint's length.
        NUMERIC = /\A\d{1,18}\z/

        def initialize(relation)
          @relation = relation
        end

        def only(ids)
          Relation.new(@relation.where(id: ids))
        end

        def excluding(ids)
          Relation.new(@relation.where.not(id: ids))
        end

        def search(query)
          columns = PermissionForge::SchemaRead.columns_among(@relation.klass, SEARCH_COLUMNS)
          id = query.to_i if query.match?(NUMERIC)
          return Relation.new(@relation.none) if columns.empty? && id.nil?

          Relation.new(@relation.where(word_conditions(columns, query.downcase, id)))
        end

        def count
          @relation.except(:order, :limit, :offset).count
        end

        def take(offset, limit)
          @relation.offset(offset).limit(limit).to_a
        end

        private

        # Every word must match some column, so "ana kras" finds Ana Krasniqi
        # whether the name lives in one column or in first/last name columns.
        # A numeric query also matches the id.
        def word_conditions(columns, needle, id)
          words = needle.split
          matched = words.map { |word| any_column(columns, word) }.compact.reduce(:and)
          return table[:id].eq(id) if matched.nil?

          id ? matched.or(table[:id].eq(id)) : matched
        end

        def any_column(columns, word)
          like = "%#{ActiveRecord::Base.sanitize_sql_like(word)}%"
          columns.map { |column| table[column].lower.matches(like) }.reduce(:or)
        end

        def table
          @relation.klass.arel_table
        end
      end

      # Array-backed (custom resolvers): searches the person's display label.
      class List
        def initialize(people, configuration)
          @people = people
          @configuration = configuration
        end

        def only(ids)
          List.new(@people.select { |u| ids.include?(u.id) }, @configuration)
        end

        def excluding(ids)
          List.new(@people.reject { |u| ids.include?(u.id) }, @configuration)
        end

        def search(query)
          needle = query.downcase
          List.new(@people.select { |u| label_text(u).include?(needle) }, @configuration)
        end

        def count
          @people.size
        end

        def take(offset, limit)
          Array(@people)[offset, limit] || []
        end

        private

        def label_text(user)
          PersonLabel.new(user, configuration: @configuration).search_text
        end
      end
    end
  end
end
