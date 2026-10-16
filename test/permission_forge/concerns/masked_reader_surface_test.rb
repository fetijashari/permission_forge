# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Concerns
    # The reader surface of a masked record, enumerated from Rails itself.
    # Every attribute-method pattern the model class knows
    # (Model.attribute_method_patterns: the getter, `?`, the dirty family,
    # `_before_type_cast`, `_in_database`, …) is called for a hidden column
    # in three states — as loaded, with a pending change, just saved — and
    # judged by what it returns. A pattern that hands out the stored value
    # must be one of RAW, the patterns docs/masked-attributes.md ("What is
    # not intercepted") documents as raw; a pattern that reveals nothing
    # must not be listed as raw. A pattern a Rails release adds lands here
    # first, on the raw side, and fails until MaskedAttributes masks it or
    # the docs and RAW name it.
    class MaskedReaderSurfaceTest < ActiveSupport::TestCase
      STORED = 'stored-secret@example.com'
      CHANGED = 'changed-secret@example.com'
      SECRETS = [STORED, CHANGED].freeze
      WRITER = ['', '='].freeze

      # [prefix, suffix] of every pattern that reads the stored value past
      # the guard — the raw paths and the dirty family of the docs table.
      RAW = [
        ['', '_before_type_cast'], ['', '_for_database'], ['', '_in_database'],
        ['', '_was'], ['', '_change'], ['', '_will_change!'], ['', '_change_to_be_saved'],
        ['', '_previous_change'], ['', '_previously_was'], ['', '_before_last_save'], ['saved_change_to_', '']
      ].freeze

      DOC = File.expand_path('../../../docs/masked-attributes.md', __dir__)

      setup do
        @user = create_user
        set = create_permission_set
        create_permission_set_user(user: @user, permission_set: set)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        create_resource_field(resource: resource, name: 'name', read_access: true)
        create_resource_field(resource: resource, name: 'email', read_access: false)
        PermissionForge::MaskedModels.apply(only: 'Customer')
        assert MaskedAttributes.applied?(Customer), 'Customer did not get MaskedAttributes'
        Current.user = @user
      end

      test 'every pattern that returns the stored value of a hidden column is a documented raw path, and every documented raw path still does' do
        verdicts = surface
        unjudged = verdicts.reject { |_, verdict| %i[raw clean].include?(verdict) }
        assert_empty unjudged.map { |pattern, verdict| "#{example(pattern)}: #{verdict}" },
                     'a pattern could not be called: judge it here'

        revealing = verdicts.select { |_, verdict| verdict == :raw }.keys
        assert_empty (revealing - RAW).map { |pattern| example(pattern) },
                     'readers of a hidden column that hand out the stored value and are documented nowhere: mask them in ' \
                     'MaskedAttributes, or add them to RAW and to the "What is not intercepted" table of docs/masked-attributes.md'
        assert_empty (RAW - revealing).map { |pattern| example(pattern) },
                     'documented as raw, but no longer hand out the stored value: remove them from RAW and from the docs table'
      end

      test 'the docs table names no raw reader as intercepted and no intercepted reader as raw' do
        rows = File.readlines(DOC).select { |line| line.start_with?('| `') }
        assert_operator rows.size, :>, 10, 'the "What is not intercepted" table moved: update DOC'
        rows.each do |row|
          named = patterns.select { |pattern| row.match?(/[`.]#{Regexp.escape(example(pattern))}`/) }
          next if named.empty?

          if row.include?('**no**')
            assert_empty (named - RAW).map { |pattern| example(pattern) }, "documented as raw but intercepted: #{row.strip}"
          else
            assert_empty (named & RAW).map { |pattern| example(pattern) }, "documented as intercepted but raw: #{row.strip}"
          end
        end
      end

      private

      # [prefix, suffix] of every pattern but the writer.
      def patterns
        Customer.attribute_method_patterns.map { |pattern| [pattern.prefix, pattern.suffix] }.uniq - [WRITER]
      end

      def example(pattern)
        prefix, suffix = pattern
        "#{prefix}email#{suffix}"
      end

      # { [prefix, suffix] => :raw | :clean | "error" }: :raw when the method
      # mentions a stored or an assigned value in any of the three states.
      def surface
        patterns.to_h do |pattern|
          [pattern, verdict(%i[loaded pending saved].map { |state| call(pattern, record_in(state)) })]
        end
      end

      def verdict(results)
        error = results.find { |result| result.is_a?(StandardError) }
        return "#{error.class}: #{error.message[0, 80]}" if error

        results.any? { |result| SECRETS.any? { |secret| result.inspect.include?(secret) } } ? :raw : :clean
      end

      # A fresh row per call: some patterns change the record (restore_x!,
      # clear_x_change) and must not colour the next one.
      def record_in(state)
        record = Customer.find(create_customer(email: STORED).id)
        case state
        when :pending then record.email = CHANGED
        when :saved then record.update!(email: CHANGED)
        end
        record
      end

      def call(pattern, record)
        record.public_send(example(pattern))
      rescue StandardError => e
        e
      end
    end
  end
end
