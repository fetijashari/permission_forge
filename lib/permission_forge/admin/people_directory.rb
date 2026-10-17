# frozen_string_literal: true

module PermissionForge
  module Admin
    # Searches and filters the people shown on the People page and in pickers.
    # The candidate list comes from config.user_list_resolver (or
    # user_model.order(:id)); search runs in SQL on whichever of the usual
    # name/email columns exist, or in Ruby for array-returning resolvers
    # (see PeopleCandidates).
    class PeopleDirectory
      FILTERS = %w[all ending expired muting no_access].freeze
      DEFAULT_PER_PAGE = 25
      # Beyond this the offset overflows the database's integer; the page is
      # empty long before.
      MAX_PAGE = (2**31) - 1
      # Filters that keep everyone *except* the matching people.
      EXCLUDING_FILTERS = %w[no_access].freeze

      # Assignments whose people a filter keeps ('no_access' keeps everyone else).
      FILTER_ASSIGNMENTS = {
        'ending' => -> { PermissionForge::PermissionSetUser.ending_within },
        'expired' => -> { PermissionForge::PermissionSetUser.expired },
        'muting' => lambda {
          PermissionForge::PermissionSetUser.active_assignments.where(permission_set_id: PermissionForge::PermissionSet.muting.select(:id))
        },
        'no_access' => lambda {
          PermissionForge::PermissionSetUser.active_assignments.where(permission_set_id: PermissionForge::PermissionSet.active.select(:id))
        }
      }.freeze

      Page = Struct.new(:people, :total, :page, :per_page, keyword_init: true) do
        def more? = total > page * per_page
        def shown = [total, page * per_page].min
      end

      def initialize(configuration: PermissionForge.configuration)
        @configuration = configuration
      end

      # Typed or pasted text, as it is searched for people: without NUL bytes
      # (the search builds quoted literals, and a NUL would cut the SQL
      # statement short) and without surrounding white space. The one input
      # boundary for people search and the bulk matcher.
      #
      # @return [String]
      def self.search_text(text)
        text.to_s.delete("\0").strip
      end

      # Paging options: page: (1-based, default 1), per_page: (default 25).
      # @return [Page]
      def search(query: nil, filter: 'all', **paging)
        filter = 'all' unless FILTERS.include?(filter.to_s)
        candidates = apply_query(apply_filter(base_candidates, filter.to_s), query)
        page = ParamShapes.integer(paging[:page], default: 1, range: 1..).clamp(1, MAX_PAGE) # the one reader: "2abc" is page 1
        paginate(candidates, page, paging.fetch(:per_page, DEFAULT_PER_PAGE))
      end

      # Counts for the filter chips (respecting the search query).
      def counts(query: nil)
        base = apply_query(base_candidates, query)
        FILTERS.index_with { |filter| apply_filter(base, filter).count }
      end

      # People matching a query, capped (for the person picker).
      def pick(query:, limit: nil)
        limit ||= @configuration.user_list_limit || 500
        candidates = apply_query(base_candidates, query)
        total = candidates.count
        Page.new(people: candidates.take(0, limit), total: total, page: 1, per_page: limit)
      end

      # The person `id` names, looked up within config.user_list
      # (user_list_resolver): the one lookup of a person by id for the admin
      # and the API. Someone the resolver leaves out (another tenant's user,
      # an account the host keeps out of the admin) is nobody here: nil,
      # which callers answer with a 404 / "not found".
      #
      # @param id [String, Integer] anything else (a Hash, an Array) names nobody
      # @return [Object, nil] the user
      def find(id)
        find_all([id]).first
      end

      # The people `ids` name within config.user_list; ids that name nobody
      # there (or are not keys at all) are dropped.
      #
      # @param ids [Array, String, Integer]
      # @return [Array] users
      def find_all(ids)
        ids = Ids.cast(ids, configuration: @configuration)
        ids.empty? ? [] : base_candidates.only(ids).take(0, ids.size)
      end

      # Request values cast to the user model's primary-key type. Only a
      # String or an Integer can name a person; for an integer key only
      # digits do (the database would read '1abc' as 1), and never past a
      # bigint. A NUL byte names nobody.
      module Ids
        INTEGER_KEY = /\A\d{1,19}\z/
        MAX_INTEGER_KEY = (2**63) - 1

        # @return [Array] distinct cast ids, in order
        def self.cast(ids, configuration: PermissionForge.configuration)
          model = configuration.user_model
          type = model.type_for_attribute(model.primary_key)
          (ids.is_a?(Array) ? ids : [ids]).filter_map { |id| cast_one(id, type) }.uniq
        end

        # The request values that name none of `found` (cast ids, e.g. the
        # people #find_all returned): each cast to the key type when it can
        # be (99, not "99"), else as sent, trimmed and without NUL bytes.
        # Blanks and values that are no id at all (an object, a list) are
        # left out.
        #
        # @return [Array] distinct, in order
        def self.unmatched(ids, found, configuration: PermissionForge.configuration)
          model = configuration.user_model
          type = model.type_for_attribute(model.primary_key)
          (ids.is_a?(Array) ? ids : [ids]).filter_map do |id|
            next unless id.is_a?(String) || id.is_a?(Integer)

            cast = cast_one(id, type)
            next id.to_s.delete("\0").strip.presence if cast.nil?

            cast unless found.include?(cast)
          end.uniq
        end

        def self.cast_one(id, type)
          return nil unless id.is_a?(String) || id.is_a?(Integer)

          text = id.to_s.strip
          return nil if text.empty? || text.include?("\0")
          return nil if type.type == :integer && !integer_key?(text)

          type.cast(text)
        end

        def self.integer_key?(text)
          text.match?(INTEGER_KEY) && text.to_i <= MAX_INTEGER_KEY
        end
        private_class_method :cast_one, :integer_key?
      end

      private

      # Memoized: an array-returning resolver is evaluated once per directory
      # (the bulk matcher asks once per pasted line).
      def base_candidates
        @base_candidates ||= PeopleCandidates.wrap(@configuration.user_list, configuration: @configuration)
      end

      def apply_filter(candidates, filter)
        ids = filter_ids(filter)
        return candidates if ids.nil?

        candidates.public_send(EXCLUDING_FILTERS.include?(filter) ? :excluding : :only, ids)
      end

      def filter_ids(filter)
        FILTER_ASSIGNMENTS[filter]&.call&.select(:user_id)
      end

      def apply_query(candidates, query)
        query = self.class.search_text(query)
        query.empty? ? candidates : candidates.search(query)
      end

      def paginate(candidates, page, per_page)
        Page.new(people: candidates.take((page - 1) * per_page, per_page), total: candidates.count, page: page,
                 per_page: per_page)
      end
    end
  end
end
