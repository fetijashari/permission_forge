# frozen_string_literal: true

module PermissionForge
  module AuditIntegration
    # Compares the permission tables before and after a request or a call
    # with the change events it wrote, whatever code made the change — so a
    # write that skips callbacks (however it is spelled) cannot hide:
    #
    # - an inserted row needs its create event, whose snapshot, with the
    #   later update events of the row applied, is the row as stored;
    # - a deleted row needs its destroy event, whose snapshot is the row as
    #   it was (with the earlier update events applied);
    # - a changed row needs update events whose `changes` lead, column by
    #   column, from the row before to the row after (from = before, to =
    #   after), and no column may change that no event names;
    # - and the other way round: every create, update and destroy event
    #   names a row that was inserted, changed or deleted (or created and
    #   destroyed inside the window, its two snapshots agreeing).
    #
    # Bookkeeping columns (created_at/updated_at/created_by_id/updated_by_id)
    # are not in `changes` by design; they are compared only where a
    # snapshot carries them, and a row whose ONLY change is bookkeeping
    # needs an event too (a `touch`).
    module TableLedger
      BOOKKEEPING = %w[created_at updated_at created_by_id updated_by_id].freeze

      # The models whose rows are audited (every RecordsAuditEvents model).
      def self.models
        @models ||= PermissionForge.constants.sort.filter_map do |name|
          model = PermissionForge.const_get(name)
          model if model.is_a?(Class) && model < ActiveRecord::Base && model < PermissionForge::Concerns::RecordsAuditEvents
        end
      end

      # { 'PermissionForge::Resource' => { id => attributes.as_json } } over every tenant.
      def self.snapshot
        models.to_h do |model|
          [model.base_class.name, model.unscoped.order(:id).to_h { |row| [row.id, row.attributes.as_json] }]
        end
      end

      # @return [Array<String>] what the events do not explain (empty: all of it)
      def self.unexplained(before, after, events)
        Explanation.new(before, after, events).problems
      end

      # What the integration tests call: ledger_events { } keeps the
      # tables before and after and the events in @ledger;
      # assert_tables_explained compares them.
      module Assertions
        private

        def ledger_events(&)
          before = TableLedger.snapshot
          events = events_during(&)
          @ledger = [before, TableLedger.snapshot, events]
          events
        end

        def assert_tables_explained(label)
          before, after, events = @ledger || flunk("#{label}: nothing ran through ledger_events")
          assert_empty TableLedger.unexplained(before, after, events), "#{label}: table changes and events disagree"
        end
      end

      # One comparison.
      class Explanation
        def initialize(before, after, events)
          @before = before
          @after = after
          @by_record = events.select { |event| event.category == 'change' && (event.data.key?('snapshot') || event.data.key?('changes')) }
                             .sort_by(&:id).group_by { |event| [event.record_type, event.record_id] }
          @problems = []
          @explained = Set.new
        end

        def problems
          TableLedger.models.each do |model|
            rows(model).each { |id, before, after| explain_row(model, id, before, after) }
            transient_ids(model).each { |id| explain_transient(model, id) }
          end
          @problems + unmatched_events
        end

        private

        def unmatched_events
          (@by_record.keys - @explained.to_a).map do |key|
            "#{@by_record[key].map(&:event).join(', ')} name #{key.join(' #')}, but no such row changed"
          end
        end

        # [id, before, after] of every row that differs (nil: absent).
        def rows(model)
          before = @before.fetch(model.base_class.name)
          after = @after.fetch(model.base_class.name)
          (before.keys | after.keys).filter_map { |id| [id, before[id], after[id]] unless before[id] == after[id] }
        end

        def explain_row(model, id, before, after)
          key = [model.base_class.name, id.to_s]
          @explained << key
          events = @by_record.fetch(key, [])
          return inserted(model, id, after, events) if before.nil?
          return deleted(model, id, before, events) if after.nil?

          changed(model, id, before, after, events)
        end

        def inserted(model, id, row, events)
          create = find(events, model, :create)
          return missing(model, id, 'inserted', :create) unless create

          check("#{model.name} ##{id} (inserted)", replay(create.data['snapshot'], updates(events), model, id), row)
        end

        def deleted(model, id, row, events)
          destroy = find(events, model, :destroy)
          return missing(model, id, 'deleted', :destroy) unless destroy

          earlier = updates(events).select { |event| event.id < destroy.id }
          check("#{model.name} ##{id} (destroy snapshot)", replay(row, earlier, model, id), destroy.data['snapshot'])
        end

        def changed(model, id, before, after, events)
          if updates(events).empty?
            columns = after.keys.reject { |column| before[column] == after[column] }
            return @problems << "#{model.name} ##{id} changed #{columns.join(', ')} without an event"
          end

          check("#{model.name} ##{id} (changed)", replay(before, updates(events), model, id), after)
        end

        # Ids named by events of rows that exist neither before nor after.
        def transient_ids(model)
          type = model.base_class.name
          @by_record.keys.select { |key| key.first == type && !@explained.include?(key) }.map(&:last)
        end

        # Created and destroyed inside the window: the destroy snapshot is
        # the create snapshot with the updates applied.
        def explain_transient(model, id)
          events = @by_record.fetch([model.base_class.name, id])
          create = find(events, model, :create)
          destroy = find(events, model, :destroy)
          return unless create && destroy

          @explained << [model.base_class.name, id]
          check("#{model.name} ##{id} (created and destroyed)", replay(create.data['snapshot'], updates(events), model, id),
                destroy.data['snapshot'])
        end

        def find(events, model, action) = events.find { |event| event.event == model.audit_event_name(action) }
        def updates(events) = events.select { |event| event.data.key?('changes') }

        def missing(model, id, what, action)
          @problems << "#{model.name} ##{id} was #{what} without #{model.audit_event_name(action)}"
        end

        # Applies the `changes` of the events to `state`, checking each `from`.
        def replay(state, events, model, id)
          events.each_with_object(state.dup) do |event, current|
            event.data['changes'].each do |column, (from, to)|
              unless current[column] == from
                @problems << "#{event.event} ##{event.id} says #{model.name} ##{id}.#{column} was #{from.inspect}, " \
                             "it was #{current[column].inspect}"
              end
              current[column] = to
            end
          end
        end

        def check(label, expected, actual)
          wrong = ((expected.keys | actual.keys) - BOOKKEEPING).reject { |column| expected[column] == actual[column] }
          return if wrong.empty?

          @problems << "#{label}: the events do not explain #{wrong.map { |c| "#{c} (#{expected[c].inspect} vs #{actual[c].inspect})" }.join(', ')}"
        end
      end
    end
  end
end
