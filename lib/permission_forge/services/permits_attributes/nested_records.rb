# frozen_string_literal: true

module PermissionForge
  module Services
    class PermitsAttributes
      # Which nested records name a row the current user may reach.
      #
      # A nested record keeps its `id` (without one a payload can only
      # create), and Rails refuses the id of another parent's row — but it
      # loads the rows of the SAME parent through the association, which is
      # not rule-scoped. So a record with an id survives only when the child
      # model has no row-level rules to ask (no PermissionScopedFindable:
      # left to Rails) or the id is inside `permission_scoped` for the current
      # user, checked in one query per payload. Otherwise the whole record
      # goes: dropping the id alone would turn an update into a create. A
      # blank id is a new record, as Rails reads it: nothing to check.
      #
      # @api private
      class NestedRecords
        # One id per record. A plain Hash may carry both 'id' and :id; Rails
        # reads the record with indifferent access (the last key wins), and
        # the guard must not check one id while Rails applies the other. The
        # same id under both keys is kept under one; two ids drop the record.
        #
        # @param record [Hash] a filtered record
        # @return [Hash, nil]
        def self.with_one_id(record)
          return record unless record.key?('id') && record.key?(:id)

          ids = [record['id'], record[:id]].map { |id| id.to_s.presence }.uniq
          record.except(:id) if ids.size == 1
        end

        # @param collection [Boolean] whether the association is a collection
        #   (has_many); a has_one / belongs_to payload is one record
        def initialize(child, collection:)
          @child = child
          @collection = collection
        end

        # @param payload [Array<Hash>, Hash] the filtered payload: an Array of
        #   records, Rails' index Hash, or one record
        # @yield once for every record of a collection that is dropped
        # @return [Array<Hash>, Hash, nil] the payload without the denied
        #   records; nil when its one record is denied
        def admit(payload, &)
          return payload unless @child.respond_to?(:permission_scoped)
          return admit_one(payload) unless @collection

          case payload
          when Array then admit_each(payload, &)
          when Hash then id_key?(payload) ? admit_one(payload) : admit_indexed(payload, &)
          else payload
          end
        end

        private

        def admit_each(records, &)
          denied = denied_ids(records)
          records.select { |record| admitted?(record, denied, &) }
        end

        def admit_indexed(records, &)
          denied = denied_ids(records.values)
          records.select { |_, record| admitted?(record, denied, &) }
        end

        def admit_one(record)
          record if denied_ids([record]).empty?
        end

        def admitted?(record, denied)
          return true unless denied.include?(id_of(record))

          yield if block_given?
          false
        end

        # The ids among the records that permission_scoped does not reach,
        # as Strings, in one query. An id that names no row is denied too.
        def denied_ids(records)
          ids = records.filter_map { |record| id_of(record) }
          return [] if ids.empty?

          key = @child.primary_key
          ids - @child.permission_scoped.where(key => ids).pluck(key).map(&:to_s)
        end

        # As Rails tells one record of a collection from the index form: by
        # the key, whatever it holds.
        def id_key?(record)
          record.key?('id') || record.key?(:id)
        end

        # The record's id as a String; nil for none or a blank one.
        def id_of(record)
          return unless record.respond_to?(:key?)

          id = record.key?('id') ? record['id'] : record[:id]
          id.to_s.presence
        end
      end
    end
  end
end
