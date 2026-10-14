module PermissionForge
  module Api
    module Pagination
      extend ActiveSupport::Concern

      # Beyond this the offset overflows the database's integer; the page is
      # empty long before.
      MAX_PAGE = (2**31) - 1

      private

      def paginate_scope(scope, paginator)
        page = current_page
        per = clamped_per_page
        paginator.call(scope, page, per)
      end

      def default_paginate_scope(scope)
        page = current_page
        per = clamped_per_page
        total = scope.count
        records = scope.limit(per).offset((page - 1) * per)
        records.define_singleton_method(:total_count) { total }
        records
      end

      def pagination_meta(paginated)
        {
          pagination: {
            page: current_page,
            per_page: clamped_per_page,
            total_count: paginated.respond_to?(:total_count) ? paginated.total_count : paginated.size
          }
        }
      end

      # Anything that is not a number (a Hash, an Array) reads as page 1.
      def current_page
        params[:page].to_s.to_i.clamp(1, MAX_PAGE)
      end

      def clamped_per_page
        config = PermissionForge.configuration
        requested = params[:per_page]
        requested = requested.nil? ? config.api_default_per_page : requested.to_s.to_i
        requested.clamp(1, config.api_max_per_page)
      end
    end
  end
end
