module PermissionForge
  module Services
    # Builds a merged permission hash for a user across multiple permission sets.
    # Uses most-permissive-wins logic for CRUD/boolean flags and AND logic for masks.
    # Muting permission sets subtract permissions after granting sets are merged.
    # Field rows are merged by {FieldPermissionMerger}; the implicit entries of
    # extra (virtual) fields are added by {ExtraFieldDefaults}.
    #
    # Every row a build reads is loaded up front, one query per table
    # (#load_permission_rows): the sets' resources with their fields, actions
    # and rules, active or not, and the user's assignment of each set with
    # the people who granted and last changed it. Inactive rows are skipped in
    # Ruby (`select(&:is_active)`) — the `active` scope would query again, per
    # resource. Each holder of a set rebuilds after any edit to it, so a
    # build must not cost a query per resource.
    #
    # @example
    #   data = PermissionHashBuilder.call(user: user, permission_sets: user.permission_sets.active)
    #   # => { resources: { Customer: { permissions: { read_access: true, ... }, fields: {...}, ... } } }
    #
    # @api public
    class PermissionHashBuilder
      RESOURCE_PERMISSION_OPTIONS = %i[read_access create_access edit_access delete_access view_all modify_all].freeze
      # The rows each resource brings into the hash (#load_permission_rows).
      RESOURCE_ROWS = %i[resource_fields resource_actions permission_set_rules].freeze
      # The columns naming who granted and last changed an assignment (HasAuditTrail).
      GRANTOR_KEYS = %w[created_by_id updated_by_id].freeze

      # Resources and their rows in id order, in place. The database returns
      # them in whatever order its plan gives, and order decides: the first row
      # of a name wins a tie (two fields mapping to one variant — "first
      # mask_strategy wins"), and rules and actions keep it in the hash. The one
      # definition: Admin::EffectiveAccess sorts the rows it shows with it. An
      # unsaved row (no id yet) sorts first.
      def self.sort_rows(permission_set)
        resources = sorted(permission_set.association(:resources))
        resources.each { |resource| RESOURCE_ROWS.each { |rows| sorted(resource.association(rows)) } }
      end

      def self.sorted(association)
        association.target.sort_by! { |row| row.id.to_i }
      end
      private_class_method :sorted

      # Builds a user's permission hash from their permission sets.
      # @param user [Object]
      # @param permission_sets [Enumerable<PermissionSet>]
      # @return [Hash]
      def self.call(user:, permission_sets:)
        new(user: user, permission_sets: permission_sets).call
      end

      def initialize(user:, permission_sets:)
        @user = user
        @permission_sets = permission_sets
      end

      # @return [Hash] the permission hash (the format is in the architecture guide)
      def call
        data = { resources: {} }
        load_permission_rows

        granting_sets, muting_sets = partition_permission_sets

        granting_sets.each { |ps| process_permission_set(data, ps) }
        add_extra_field_defaults(data)
        muting_sets.each { |ps| apply_muting_permission_set(data, ps) }

        data
      end

      private

      def partition_permission_sets
        @permission_sets.partition { |ps| !ps.is_muting }
      end

      # --- Loading (every row of the build, one query per table) ---

      # The sets in the order given (created_at, id: "first mask_strategy
      # wins" depends on it), each with its resources and their rows loaded.
      def load_permission_rows
        @permission_sets = @permission_sets.to_a
        preload(@permission_sets, resources: RESOURCE_ROWS)
        @permission_sets.each { |permission_set| self.class.sort_rows(permission_set) }
        @assignments = assignments_by_set
      end

      # The user's assignment of each set (any row of the pair, as find_by
      # would answer), with its grantors.
      def assignments_by_set
        return {} if @permission_sets.empty?

        assignments = PermissionForge::PermissionSetUser.where(user_id: @user.id, permission_set_id: @permission_sets.map(&:id)).to_a
        preload_grantors(assignments)
        assignments.each_with_object({}) { |assignment, by_set| by_set[assignment.permission_set_id] ||= assignment }
      end

      # Only where an assignment names one: preloading builds the user
      # model's scope — its default scopes run — even for no id at all, which
      # the association readers never did.
      def preload_grantors(assignments)
        stamped = assignments.select { |assignment| GRANTOR_KEYS.any? { |key| assignment[key] } }
        preload(stamped, %i[created_by updated_by]) if stamped.any?
      end

      def preload(records, associations)
        ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
      end

      # --- Granting logic (additive, most-permissive-wins) ---

      def process_permission_set(data, permission_set)
        permission_set.resources.select(&:is_active).each do |resource|
          process_resource(data, permission_set, resource)
        end
      end

      def process_resource(data, permission_set, resource)
        return unless resource.is_active

        resource_data = init_resource_data(data, resource.name)

        add_source_permission_set(resource_data[:source_permission_sets], permission_set)
        merge_resource_permissions(resource_data[:permissions], resource)
        FieldPermissionMerger.call(fields: resource_data[:fields], resource: resource)
        merge_resource_actions(resource_data[:actions], resource)
        merge_permission_set_rules(resource_data[:permission_set_rules], resource)
      end

      # Once per resource, after every granting set and before muting: a
      # ResourceField row in any of the user's sets wins over the implicit
      # grant, whichever set is older, and the grant follows the resource's
      # merged read and edit.
      def add_extra_field_defaults(data)
        data[:resources].each do |name, resource_data|
          ExtraFieldDefaults.call(entry: resource_data, resource_name: name)
        end
      end

      def init_resource_data(data, name)
        data[:resources][name] ||= {
          permissions: {},
          fields: {},
          actions: {},
          source_permission_sets: [],
          permission_set_rules: []
        }
      end

      def add_source_permission_set(source_permission_sets, permission_set)
        permission_set_user = @assignments[permission_set.id]

        source_permission_sets << {
          uuid: permission_set.uuid,
          name: permission_set.name,
          is_muting: permission_set.is_muting,
          permission_set_granted_by: user_reference(permission_set_user&.created_by),
          permission_set_granted_updated_by: user_reference(permission_set_user&.updated_by),
          permission_set_granted_at: permission_set_user&.created_at,
          permission_set_granted_updated_at: permission_set_user&.updated_at
        }
      end

      # Who granted or last changed an assignment: the person's uuid when the
      # audit user model has one, else their id. Nothing asks a host user
      # model for a uuid column.
      def user_reference(user)
        return unless user

        user.respond_to?(:uuid) ? user.uuid : user.id
      end

      def merge_resource_permissions(permissions, resource)
        RESOURCE_PERMISSION_OPTIONS.each do |action|
          permissions[action] ||= resource.send(action)
        end
      end

      def merge_resource_actions(actions, resource)
        resource.resource_actions.select(&:is_active).each do |action|
          key = action.name.to_sym
          if actions.key?(key)
            actions[key][:is_permitted] ||= action.is_permitted
          else
            actions[key] = { is_permitted: action.is_permitted }
          end
        end
      end

      def merge_permission_set_rules(permission_set_rules, resource)
        resource.permission_set_rules.select(&:is_active).each do |rule|
          permission_set_rules << {
            name: rule.name,
            failure_message: rule.failure_message,
            join_type: rule.join_type,
            field_name: rule.field_name,
            field_value: rule.field_value,
            field_accessor_path: rule.field_accessor_path,
            operator: rule.operator,
            include_nulls: rule.include_nulls
          }
        end
      end

      # --- Muting logic (subtractive, deny overrides allow) ---

      # A muting resource reaches every entry whose resource chain names it
      # (ResourceChain): the entry of its own name and, when it names a
      # model, the entries of that model's STI subclasses. A subclass can
      # only be narrower than its base, and the CRUD flags, the bypasses and
      # the actions are read from one entry (can_*?, the controller guard):
      # a muted base that left the subclass entry whole let the subclass
      # controller destroy the row the admin believed muted, while the rows
      # and fields, composed along the chain, were already closed. A muting
      # row naming a subclass reaches that subclass alone.
      def apply_muting_permission_set(data, permission_set)
        permission_set.resources.select(&:is_active).each do |resource|
          entries_under(data, resource.name).each do |resource_data|
            apply_muting_resource(resource_data, permission_set, resource)
          end
        end
      end

      # The entries whose chain includes the resource name, in hash order;
      # each entry's chain is worked out once per build.
      def entries_under(data, name)
        muted = name.to_sym
        @entry_chains ||= {}
        data[:resources].filter_map do |entry_name, resource_data|
          chain = (@entry_chains[entry_name] ||= PermissionForge::ResourceChain.names_for(entry_name))
          resource_data if chain.include?(muted)
        end
      end

      # The set is listed once per entry: one with rows for a base and its
      # subclass reaches the subclass entry twice.
      def apply_muting_resource(resource_data, permission_set, resource)
        sources = resource_data[:source_permission_sets]
        add_source_permission_set(sources, permission_set) if sources.none? { |source| source[:uuid] == permission_set.uuid }
        mute_resource_permissions(resource_data[:permissions], resource)
        mute_field_permissions(resource_data[:fields], resource)
        mute_fields_of_resource(resource_data[:fields], resource)
        mute_resource_actions(resource_data[:actions], resource)
      end

      def mute_resource_permissions(permissions, resource)
        RESOURCE_PERMISSION_OPTIONS.each do |action|
          permissions[action] = false if resource.send(action)
        end
      end

      # A muting set that revokes the resource's read revokes read and edit on
      # every field of the resource; variants and implicit extra fields are
      # entries too. Field enforcement (getters, as_json, the filters) reads
      # the field entries only, so muting the resource used to protect less
      # than never granting it. Read only: PermitsAttributes filters creates
      # too, so the same cascade on edit would block a user who may create but
      # not change ("can submit, cannot edit afterwards"). Granting sets are
      # left to their field rows, as before.
      def mute_fields_of_resource(fields, resource)
        return unless resource.read_access

        fields.each_value do |entry|
          entry[:read_access] = false
          entry[:edit_access] = false
        end
      end

      def mute_field_permissions(fields, resource)
        resource.resource_fields.select(&:is_active).each do |field|
          next unless field.is_active

          # Mute the base field AND every configured variant (_uuid, base name for
          # _cents, etc.), matching the variants the granting phase writes — otherwise
          # a muting set that revokes `user_id` would leave `user_uuid` readable.
          mute_single_field(fields, field.name, field)
          PermissionForge.configuration.field_variants_for(field.name).each do |variant|
            mute_single_field(fields, variant, field)
          end
        end
      end

      # A row that mutes read mutes edit too: a field nobody may read is not
      # one they may write (the admin UI's Hide writes both flags; the API
      # and code can write read alone, which left the field writable through
      # PermitsAttributes). Admin::EffectiveFields#mute_field says the same.
      def mute_single_field(fields, field_name, field)
        entry = fields[field_name]
        return unless entry

        entry[:read_access] = false if field.read_access
        entry[:edit_access] = false if field.read_access || field.edit_access
        entry[:mask_access] = true if field.mask_access
      end

      def mute_resource_actions(actions, resource)
        resource.resource_actions.select(&:is_active).each do |action|
          key = action.name.to_sym
          actions[key][:is_permitted] = false if actions.key?(key) && action.is_permitted
        end
      end
    end
  end
end
