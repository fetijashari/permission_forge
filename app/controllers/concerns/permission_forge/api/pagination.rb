module PermissionForge
  module Api
    module Pagination
      extend ActiveSupport::Concern

      # Beyond this the offset overflows the database's integer; the page is
      # empty long before.
      MAX_PAGE = (2**31) - 1
      # What a page or a page size is: a positive whole number
      # (ParamShapes#pf_integer_param reads it; "abc", "0", "-1", "2abc",
      # 1.5 and a list are not one).
      POSITIVE = (1..)

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

      # params[:page] when it is a positive whole number (at most MAX_PAGE),
      # else the first page.
      def current_page
        pf_integer_param(:page, default: 1, range: POSITIVE).clamp(1, MAX_PAGE)
      end

      # params[:per_page] when it is a positive whole number, else
      # config.api_default_per_page; never above config.api_max_per_page.
      # A typo (`per_page=abc`), 0 or a negative number is the default page
      # size, not a page of one row (through 0.14.1 they read as 1).
      def clamped_per_page
        config = PermissionForge.configuration
        pf_integer_param(:per_page, default: config.api_default_per_page, range: POSITIVE).clamp(1, config.api_max_per_page)
      end
    end
  end
end
