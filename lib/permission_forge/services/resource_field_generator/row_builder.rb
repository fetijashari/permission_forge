# frozen_string_literal: true

module PermissionForge
  module Services
    class ResourceFieldGenerator
      # The one definition of a generated field row: the attributes a
      # ResourceField gets when a path creates rows for a model's columns at
      # a level — ResourceFieldGenerator (the API's generate_fields,
      # Resource.grant_full_access!, the console), the admin's presets and
      # "Sync fields" (Admin::ColumnFields) and the Fields tab's bulk add
      # (Admin::ChangeSetParts::NewFields). Three paths, one row
      # (release_readiness/decision_parity_test.rb, part a):
      #
      # - the flags of the level (PermissionForge::FieldLevel), with the
      #   privacy default: under gdpr_defaults, on a granting set, a column
      #   that looks like personal data (PermissionForge::SensitiveColumns)
      #   created Read-only starts Masked. Editable is full access and masks
      #   nothing; Hidden stays Hidden (a privacy default never grants). A
      #   Muting Permission Set gets the level chosen: there a row takes
      #   access away, and the privacy default has nothing to add;
      # - then Editable is Read-only on a Resource without Edit
      #   (FieldLevel.capped): chosen Editable, a personal-data field is
      #   Read-only there, not Masked;
      # - Rails' timestamps at most Read-only on a granting set
      #   (PermissionForge::TimestampFields);
      # - the recommended mask strategy of a sensitive column, whether or not
      #   the row is masked now, so masking it later uses the right one;
      #   'full' otherwise;
      # - the label (the name itself: never English made up from it — the
      #   admin shows the host's translation, or the name), active, editable.
      #
      # A blank name (a host whose extra_fields_method lists one) is no row,
      # nor is a level that is none (FieldLevel.row?: Unchanged on a Muting
      # Permission Set mutes nothing, so no path writes a row for it).
      #
      # @api private
      class RowBuilder
        # Granting levels the privacy default turns into Masked for a column
        # that looks like personal data.
        MASKED_BY_PRIVACY_DEFAULTS = %w[read].freeze

        # @param resource [Resource] the rows' Resource (its name resolves the model)
        # @param muting [Boolean, nil] the rows are a Muting Permission Set's
        #   (default: the Resource's set says)
        # @param configuration [Configuration]
        # @param sensitive [SensitiveColumns] the matcher (default: one on `configuration`)
        def initialize(resource, muting: nil, configuration: PermissionForge.configuration, sensitive: nil)
          @resource = resource
          @muting = muting.nil? ? (resource.permission_set&.is_muting || false) : muting
          @configuration = configuration
          @sensitive = sensitive || PermissionForge::SensitiveColumns.new(configuration: configuration)
        end

        # @return [Boolean] the rows are a Muting Permission Set's
        def muting? = @muting

        # @param column [String, Symbol] the field name (a column or a virtual field)
        # @param level [String] a FieldLevel of the set's kind
        # @return [Hash, nil] the row's attributes (without the Resource), or
        #   nil for a blank name or a level that is no row
        # @raise [ArgumentError] a level the set's kind does not have
        def attrs(column, level)
          name = column.to_s
          return if name.strip.empty?
          return unless row_level?(level)

          match = @sensitive.match(name)
          level = PermissionForge::FieldLevel.capped(effective_level(level, match), resource_edit: @resource.edit_access, muting: @muting)
          flags = PermissionForge::FieldLevel.flags_for(level, muting: @muting)
          { name: name, label: name, is_active: true, is_editable: true, mask_strategy: match&.strategy || 'full' }
            .merge(flags)
            .merge(timestamps.overrides(name, read: flags[:read_access]))
        end

        private

        def row_level?(level)
          PermissionForge::FieldLevel.flags_for(level, muting: @muting) # raises for a level the kind lacks
          PermissionForge::FieldLevel.row?(level, muting: @muting)
        end

        # The level after the privacy default.
        def effective_level(level, match)
          level = level.to_s
          return level if @muting || match.nil? || !@configuration.gdpr_defaults

          MASKED_BY_PRIVACY_DEFAULTS.include?(level) ? 'masked' : level
        end

        def timestamps
          @timestamps ||= PermissionForge::TimestampFields.new(PermissionForge::ModelLookup.model_for(@resource.name), muting: @muting)
        end
      end
    end
  end
end
