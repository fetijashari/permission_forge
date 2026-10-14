# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Edits to one resource: label/description, then CRUD/scope flags with
      # the Read/Edit cascades (skipped for muting sets — inverted semantics).
      class ResourceEdit
        FLAGS = %w[read_access create_access edit_access delete_access view_all modify_all is_active].freeze
        TEXT = %w[label description].freeze
        READ_DEPENDENT = %w[edit_access delete_access view_all modify_all].freeze

        def initialize(resource, muting:)
          @resource = resource
          @muting = muting
        end

        def changes(attrs)
          text_changes(attrs.slice(*TEXT)) + flag_changes(attrs.slice(*FLAGS).transform_values { |v| Values.truthy?(v) })
        end

        private

        def text_changes(texts)
          texts.filter_map { |attr, value| change(attr, value.to_s.strip.presence, kind: :resource_text).assign }
        end

        # A flag is "cascaded" when its new value differs from (or was not
        # part of) the request.
        def flag_changes(requested)
          wanted = wanted_flags(requested)
          FLAGS.filter_map do |flag|
            to = wanted[flag]
            change(flag, to, kind: :resource_flag, cascaded: requested.fetch(flag, :absent) != to).assign
          end
        end

        def wanted_flags(requested)
          wanted = FLAGS.to_h { |flag| [flag, requested.fetch(flag) { @resource.public_send(flag) }] }
          cascade!(wanted) unless @muting
          wanted
        end

        def cascade!(flags)
          READ_DEPENDENT.each { |flag| flags[flag] = false } unless flags['read_access']
          flags['modify_all'] = false unless flags['edit_access'] && flags['view_all']
        end

        def change(attribute, to, **attrs)
          ChangeSet::Change.new(record: @resource, resource: @resource, attribute: attribute, to: to, **attrs)
        end
      end
    end
  end
end
