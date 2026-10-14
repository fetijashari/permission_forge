# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # State shared by every ChangeSet collaborator: the permission set, the
      # normalized params and the in-memory resources. Each part mutates these
      # same resource/field objects, so later parts see earlier parts' edits
      # (e.g. field levels see the resource's new Edit flag).
      class Context
        attr_reader :permission_set, :params, :sensitive

        def initialize(permission_set:, params:, sensitive:, catalog: nil)
          @permission_set = permission_set
          @params = params
          @sensitive = sensitive
          @controller_catalog = catalog
          @muting = permission_set.is_muting
        end

        # The app's controller actions (see NewActions). Built on first use:
        # most change sets never read the route table.
        def controller_catalog
          @controller_catalog ||= ControllerCatalog.new
        end

        def muting?
          @muting
        end

        # One params section (e.g. 'fields', 'bulk'), or an empty hash — also
        # when the request sent something else than a Hash there.
        def section(key)
          value = @params[key]
          value.is_a?(Hash) ? value : {}
        end

        def resources
          @resources ||= @permission_set.resources.includes(:resource_fields).index_by { |r| r.id.to_s }
        end

        # The in-memory resource (with this change set's flag edits applied) — not
        # record.resource, which may be a separately loaded copy.
        def resource_of(record)
          resources[record.resource_id.to_s]
        end
      end
    end
  end
end
