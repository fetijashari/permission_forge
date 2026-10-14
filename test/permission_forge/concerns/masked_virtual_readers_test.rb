require 'test_helper'
require_relative '../virtual_field_models'

# A subclass that overrides a reader its parent already wraps.
class PfVirtualChildProfile < PfVirtualProfile
  def display_name
    'child display name'
  end
end

# Declares a virtual field but never gets MaskedAttributes (no Resource row).
class PfVirtualPlainProfile < ApplicationRecord
  self.table_name = 'customers'

  def self.extra_fields_for_permissions
    %w[display_name]
  end

  def display_name
    'plain'
  end
end

# Gets MaskedAttributes, and its reader wrapped, only from the engine: when the
# engine test below creates its Resource. Nothing else may name it.
class PfVirtualEngineAppliedAccount < ApplicationRecord
  self.table_name = 'customers'

  def self.extra_fields_for_permissions
    %w[full_address]
  end

  def full_address
    read_attribute_before_type_cast('name').to_s
  end
end

module PermissionForge
  module Concerns
    # Model-level masking of virtual readers (config.mask_virtual_attributes).
    # PfVirtualProfile's readers are wrapped once and stay wrapped; every test
    # turns the config on itself, because the wrappers decide at call time.
    class MaskedVirtualReadersTest < ActiveSupport::TestCase
      RAW_NAME = 'Acme Corp / contact@acme.com'.freeze

      setup do
        @config = PermissionForge.configuration
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'PfVirtualProfile', read_access: true)
        @config.unconfigured_field_strategy = :pass_through
        @config.extra_fields_default_access = :unconfigured
        @config.virtual_field_discovery = true
        ::PfVirtualProfile.pf_mask_virtual_readers
        @config.mask_virtual_attributes = :auto
        @profile = ::PfVirtualProfile.create!(uuid: SecureRandom.uuid, name: 'Acme Corp', email: 'contact@acme.com',
                                              nickname: 'Ace', theme: 'dark')
        Current.user = @user
      end

      teardown do
        @config.hidden_attribute_value = nil
        @config.omit_hidden_in_attributes_hash = true
        @config.on_field_filtered = nil
        @config.custom_mask_strategies = {}
      end

      def configure(name, **flags)
        create_resource_field(resource: @resource, name: name, label: name.humanize, **flags)
        @user.regenerate_permissions
      end

      # Records on_field_filtered calls for PfVirtualProfile only: other models
      # (User, while the permission hash is built) may be masked in this process too.
      def record_filtered
        seen = []
        @config.on_field_filtered = lambda do |resource_name:, field_name:, action:, **|
          seen << [field_name, action] if resource_name == 'PfVirtualProfile'
        end
        seen
      end

      # --- what gets wrapped --------------------------------------------------

      test 'wraps declared and discovered readers, and nothing it must not touch' do
        wrapped = ::PfVirtualProfile.pf_masked_virtual_readers

        assert_equal %w[badge_count display_name domain_color greeting joined_on nickname size_domain tags theme tier],
                     wrapped.sort
        assert_equal @profile.id, ::PfVirtualProfile.find(@profile.id).id
        assert_equal 'Acme Corp', @profile.name
        assert_equal 'formatted:x', @profile.needs_argument('x')
        assert_not_respond_to @profile, :missing_reader
        assert_kind_of Hash, @profile.attributes
      end

      test 'wrapping is idempotent' do
        assert_empty ::PfVirtualProfile.pf_mask_virtual_readers
        assert_empty ::PfVirtualProfile.pf_mask_virtual_readers(%w[display_name id name needs_argument missing_reader])

        configure('display_name', read_access: true, mask_access: true)
        seen = record_filtered
        @profile.display_name

        assert_equal [%i[display_name masked]], seen
      end

      test 'explicit names that are not readers are refused' do
        assert_empty ::PfVirtualProfile.pf_mask_virtual_readers(%w[save destroy to_param Bad-Name display_name=])
        assert_equal @profile, @profile.tap(&:save!)
      end

      # --- the decision -------------------------------------------------------

      test 'a hidden virtual field returns the hidden value' do
        configure('display_name', read_access: false)
        assert_nil @profile.display_name

        @config.hidden_attribute_value = :redacted
        assert_equal :redacted, @profile.display_name
      end

      test 'a masked string returns its mask' do
        configure('display_name', read_access: true, mask_access: true, mask_strategy: 'last4')

        assert_equal "#{'*' * (RAW_NAME.length - 4)}.com", @profile.display_name
      end

      test 'a masked number or symbol returns its mask' do
        configure('badge_count', read_access: true, mask_access: true)
        configure('tier', read_access: true, mask_access: true)

        assert_equal '*' * 8, @profile.badge_count
        assert_equal '*' * 8, @profile.tier
      end

      test 'a masked value that is not a string, symbol or number is hidden, never masked from its to_s' do
        configure('tags', read_access: true, mask_access: true)
        configure('joined_on', read_access: true, mask_access: true)
        assert_nil @profile.tags
        assert_nil @profile.joined_on

        @config.hidden_attribute_value = :redacted
        assert_equal :redacted, @profile.tags
        assert_equal :redacted, @profile.joined_on
      end

      # A custom strategy may hand a value it does not recognise back unchanged.
      test 'a masked value that cannot be masked is hidden even when the strategy returns its input' do
        @config.custom_mask_strategies = { 'iban' => ->(value) { value.match?(/\A[A-Z]{2}\d{2}/) ? '****' : value } }
        configure('tags', read_access: true, mask_access: true, mask_strategy: 'iban')
        configure('joined_on', read_access: true, mask_access: true, mask_strategy: 'iban')
        seen = record_filtered

        assert_nil @profile.tags
        assert_nil @profile.joined_on
        assert_equal [%i[tags masked], %i[joined_on masked]], seen
        assert_equal(%w[vip beta], @profile.pf_without_virtual_masking { @profile.tags })

        @config.hidden_attribute_value = :redacted
        assert_equal :redacted, @profile.tags
      end

      test 'an unconfigured value that cannot be masked is hidden under :mask_all, whatever the full strategy returns' do
        @config.custom_mask_strategies = { 'full' => ->(value) { value } }
        @config.unconfigured_field_strategy = :mask_all

        assert_nil @profile.tags
        assert_nil @profile.joined_on
      end

      test 'a readable virtual field returns the raw value, whatever its type' do
        configure('display_name', read_access: true)
        configure('tags', read_access: true)

        assert_equal RAW_NAME, @profile.display_name
        assert_equal %w[vip beta], @profile.tags
      end

      test 'a virtual field nobody configured follows unconfigured_field_strategy' do
        assert_equal RAW_NAME, @profile.display_name
        assert_equal %w[vip beta], @profile.tags

        @config.unconfigured_field_strategy = :block
        assert_nil @profile.display_name
        assert_nil @profile.tags

        @config.unconfigured_field_strategy = :mask_all
        assert_equal '*' * 8, @profile.display_name
        assert_nil @profile.tags
      end

      test 'the implicit grant makes a declared virtual field readable on the model too' do
        @config.unconfigured_field_strategy = :block
        @config.extra_fields_default_access = :grant
        configure('domain', read_access: true)

        assert_equal RAW_NAME, @profile.display_name
        assert_nil @profile.theme, 'a discovered name never gets the implicit grant'
      end

      test 'readers that take optional arguments keep them' do
        assert_equal 'Hi, Acme Corp', @profile.greeting('Hi')

        configure('greeting', read_access: true, mask_access: true)
        assert_equal '*' * 8, @profile.greeting('Hi')
        assert_equal '*' * 8, @profile.greeting
      end

      test 'without a current user nothing is masked' do
        configure('display_name', read_access: false)
        Current.user = nil

        assert_equal RAW_NAME, @profile.display_name
      end

      test 'the decision comes from AttributeAccessGuard and fires on_field_filtered' do
        configure('display_name', read_access: false)
        configure('tags', read_access: true, mask_access: true)
        seen = record_filtered
        @profile.display_name
        @profile.tags
        @profile.badge_count

        assert_equal [%i[display_name hidden], %i[tags masked], %i[badge_count unconfigured]], seen
      end

      # --- attribute-API attributes and store accessors -------------------------

      test 'an attribute-API virtual goes through read_attribute like a column' do
        assert_equal 'Ace', @profile.nickname

        configure('nickname', read_access: true, mask_access: true)
        assert_equal '*' * 8, @profile.nickname
        assert_equal '*' * 8, @profile.read_attribute(:nickname)
        assert_equal('Ace', @profile.pf_without_virtual_masking { @profile.nickname })
      end

      test 'without the option the attributes hash still guards an attribute-API virtual, the getter does not' do
        configure('nickname', read_access: false)
        @config.mask_virtual_attributes = false

        assert_equal 'Ace', @profile.nickname
        assert_not @profile.attributes.key?('nickname')
        assert_not @profile.as_json.key?('nickname')
      end

      test 'a store accessor is masked by its reader name' do
        @profile.domain_color = 'teal'
        configure('theme', read_access: false)
        configure('domain_color', read_access: true, mask_access: true)

        assert_nil @profile.theme
        assert_equal '*' * 8, @profile.domain_color
        assert_equal 'dark', @profile.domain['theme'], 'the store column is a separate field with its own level'
      end

      test 'a store accessor cannot read through a hidden store column' do
        configure('domain', read_access: false)
        configure('theme', read_access: true)

        assert_nil @profile.theme
      end

      # --- live toggle ----------------------------------------------------------

      test 'a wrapped class is inert while the config does not select it' do
        configure('display_name', read_access: false)
        configure('nickname', read_access: false)

        [false, nil, %w[Customer], :typo].each do |setting|
          @config.mask_virtual_attributes = setting
          assert_equal RAW_NAME, @profile.display_name, "setting #{setting.inspect}"
          assert_equal 'Ace', @profile.nickname, "setting #{setting.inspect}"
        end

        [true, :auto, %w[PfVirtualProfile]].each do |setting|
          @config.mask_virtual_attributes = setting
          assert_nil @profile.display_name, "setting #{setting.inspect}"
          assert_nil @profile.nickname, "setting #{setting.inspect}"
        end
      end

      test 'VirtualReaders.masked? is true only for a wrapped reader on a model the config selects' do
        readers = MaskedAttributes::VirtualReaders

        assert readers.masked?(::PfVirtualProfile, :display_name)
        assert_not readers.masked?(::PfVirtualProfile, 'missing_reader'), 'declared, but there is no reader to wrap'
        assert_not readers.masked?(::PfVirtualProfile, 'name'), 'a column is not a virtual reader'
        assert_not readers.masked?(::PfVirtualPlainProfile, 'display_name'), 'the model has no MaskedAttributes'

        @config.mask_virtual_attributes = %w[Customer]
        assert_not readers.masked?(::PfVirtualProfile, 'display_name')
      end

      test 'VirtualReaders.masked? is false for a reader a subclass overrides without wrapping it' do
        child = Class.new(::PfVirtualProfile) do
          def self.name = 'PfVirtualProfile'
          def display_name = 'overridden'
        end
        readers = MaskedAttributes::VirtualReaders
        configure('display_name', read_access: false)

        assert_equal 'overridden', child.find(@profile.id).display_name, 'the override is what runs, unmasked'
        assert_not readers.masked?(child, 'display_name')
        assert readers.masked?(child, 'tags'), 'an inherited wrapper still masks'
      end

      # --- escape hatch ---------------------------------------------------------

      test 'pf_without_virtual_masking gives the raw value for the block only' do
        configure('display_name', read_access: false)

        assert_equal(RAW_NAME, @profile.pf_without_virtual_masking { @profile.display_name })
        assert_nil @profile.display_name
      end

      test 'pf_without_virtual_masking leaves column masking on' do
        configure('email', read_access: true, mask_access: true, mask_strategy: 'email')

        assert_equal('c***@acme.com', @profile.pf_without_virtual_masking { @profile.email })
      end

      test 'a model can wrap explicit names that are not declared virtual fields' do
        klass = Class.new(::PfVirtualPlainProfile) do
          include PermissionForge::Concerns::MaskedAttributes

          def self.name = 'PfVirtualProfile'
          def credit_score = 720

          pf_mask_virtual_readers(%w[credit_score])
        end
        configure('credit_score', read_access: true, mask_access: true)

        assert_equal %w[credit_score], klass.pf_masked_virtual_readers
        assert_equal '*' * 8, klass.find(@profile.id).credit_score
      end

      test 'pf_without_virtual_masking is scoped to the instance, nests and survives an exception' do
        configure('display_name', read_access: false)
        other = ::PfVirtualProfile.find(@profile.id)

        @profile.pf_without_virtual_masking do
          assert_nil other.display_name
          @profile.pf_without_virtual_masking { assert_equal RAW_NAME, @profile.display_name }
          assert_equal RAW_NAME, @profile.display_name, 'the inner block must not switch masking back on'
        end
        assert_raises(RuntimeError) { @profile.pf_without_virtual_masking { raise 'boom' } }

        assert_nil @profile.display_name
      end

      test 'a copy made inside pf_without_virtual_masking stays masked' do
        configure('display_name', read_access: false)
        copies = @profile.pf_without_virtual_masking { [@profile.dup, @profile.clone, Marshal.load(Marshal.dump(@profile))] }

        copies.each { |copy| assert_nil copy.display_name }
        @profile.pf_without_virtual_masking do
          copies.each { |copy| assert_nil copy.display_name, 'only the record itself is unmasked' }
        end
      end

      test 'pf_without_virtual_masking does not reach into another thread' do
        configure('display_name', read_access: false)
        user = @user
        seen = @profile.pf_without_virtual_masking do
          Thread.new do
            Current.user = user
            @profile.display_name
          end.value
        end

        assert_nil seen
      end

      # --- serialization --------------------------------------------------------

      test 'serializable_hash drops hidden virtual names from methods' do
        configure('display_name', read_access: false)
        configure('badge_count', read_access: true, mask_access: true)
        json = @profile.as_json(methods: %i[display_name badge_count tags])

        assert_not json.key?('display_name')
        assert_equal '*' * 8, json['badge_count']
        assert_equal %w[vip beta], json['tags']
        assert_not @profile.serializable_hash(methods: :display_name).key?('display_name')
      end

      test 'a hidden virtual name dropped from methods is listed in field.access' do
        configure('display_name', read_access: false)
        seen = []
        subscriber = ActiveSupport::Notifications.subscribe('field.access.permission_forge') { |*, payload| seen << payload }
        json = @profile.as_json(methods: %i[display_name tags])
        ActiveSupport::Notifications.unsubscribe(subscriber)

        assert_not json.key?('display_name')
        assert_equal 1, seen.size, 'one read of the record'
        assert_includes seen.first[:data]['hidden'], 'display_name'
      end

      test 'serializable_hash keeps hidden virtual names when omit_hidden_in_attributes_hash is off' do
        configure('display_name', read_access: false)
        @config.omit_hidden_in_attributes_hash = false
        json = @profile.as_json(methods: [:display_name])

        assert json.key?('display_name')
        assert_nil json['display_name']
      end

      test 'serializable_hash leaves methods alone while the config does not select the model' do
        configure('display_name', read_access: false)
        @config.mask_virtual_attributes = false
        options = { methods: [:display_name] }

        assert_equal RAW_NAME, @profile.as_json(options)['display_name']
        assert_equal({ methods: [:display_name] }, options)
        assert_kind_of Hash, @profile.serializable_hash
      end

      # --- subclasses -----------------------------------------------------------

      test 'a subclass wraps a reader it overrides and reuses the readers it inherits' do
        assert_equal %w[display_name], ::PfVirtualChildProfile.pf_mask_virtual_readers(%w[display_name tags])
        assert_includes ::PfVirtualChildProfile.pf_masked_virtual_readers, 'tags'
        child = ::PfVirtualChildProfile.find(@profile.id)

        assert_equal 'child display name', child.display_name

        @config.unconfigured_field_strategy = :block
        assert_nil child.display_name
        assert_nil child.tags
      end

      # --- diagnostics ----------------------------------------------------------

      test 'explain_all reports the decision for masked virtual readers' do
        configure('display_name', read_access: true, mask_access: true)
        configure('tags', read_access: false)
        rows = nil
        capture_io { rows = PermissionForge::Concerns::MaskedAttributes.explain_all(@profile) }
        by_name = rows.select { |row| row[:virtual] }.index_by { |row| row[:attribute] }

        assert_equal :masked, by_name['display_name'][:decision]
        assert_equal RAW_NAME, by_name['display_name'][:raw]
        assert_equal '*' * 8, by_name['display_name'][:returned]
        assert_equal :hidden_no_read_access, by_name['tags'][:decision]
        assert_equal :unconfigured, by_name['badge_count'][:decision]
        assert_not by_name.key?('missing_reader')
      end
    end

    # The engine wraps virtual readers at boot and when a Resource is created.
    class MaskedVirtualReadersEngineTest < ActiveSupport::TestCase
      include VirtualFieldTestSupport

      setup { @config = PermissionForge.configuration }

      test 'the engine wraps a model that included the concern itself, once the config selects it' do
        create_resource(permission_set: create_permission_set, name: 'PfVirtualEngineProfile')
        assert_empty ::PfVirtualEngineProfile.pf_masked_virtual_readers

        @config.mask_virtual_attributes = %w[NoSuchModel]
        PermissionForge::MaskedModels.apply
        assert_empty ::PfVirtualEngineProfile.pf_masked_virtual_readers

        @config.auto_apply_masked_attributes = false
        @config.mask_virtual_attributes = %w[PfVirtualEngineProfile]
        PermissionForge::MaskedModels.apply
        assert_equal %w[display_name], ::PfVirtualEngineProfile.pf_masked_virtual_readers
      end

      test 'creating a Resource applies the concern and wraps the virtual readers' do
        assert_not PermissionForge::Concerns::MaskedAttributes.applied?(::PfVirtualEngineAppliedAccount)

        @config.mask_virtual_attributes = :auto
        create_resource(permission_set: create_permission_set, name: 'PfVirtualEngineAppliedAccount')

        assert PermissionForge::Concerns::MaskedAttributes.applied?(::PfVirtualEngineAppliedAccount)
        assert_equal %w[full_address], ::PfVirtualEngineAppliedAccount.pf_masked_virtual_readers
      end

      test 'a model whose extra-fields method raises is left unwrapped, and the log says its readers are not masked' do
        @config.mask_virtual_attributes = :auto
        log = captured_log { assert_empty PermissionForge::MaskedModels.mask_virtual_readers('PfVirtualBrokenProfile') }

        assert_empty ::PfVirtualBrokenProfile.pf_masked_virtual_readers
        assert_match(/PfVirtualBrokenProfile\.extra_fields_for_permissions raised ArgumentError: extra fields are broken/, log)
        assert_match(/virtual readers PfVirtualBrokenProfile declares are NOT masked on the model/, log)
      end

      test 'listing the readers of such a model logs the error, without the claim about masking' do
        log = captured_log { assert_empty ::PfVirtualBrokenProfile.pf_virtual_readers }

        assert_match(/PfVirtualBrokenProfile\.extra_fields_for_permissions raised ArgumentError/, log)
        assert_no_match(/NOT masked/, log)
      end

      test 'explicit names are wrapped without reading the extra-fields method' do
        klass = Class.new(::PfVirtualBrokenProfile) do
          def self.name = 'PfVirtualBrokenProfile'
          def nickname_for_display = 'explicit'
        end
        log = captured_log { assert_equal %w[nickname_for_display], klass.pf_mask_virtual_readers(%w[nickname_for_display]) }

        assert_empty log
      end

      test 'the engine skips names that are not models or lack the concern' do
        @config.mask_virtual_attributes = %w[NoSuchModel PfVirtualPlainProfile]

        assert_nothing_raised { PermissionForge::MaskedModels.apply }
        assert_nil PermissionForge::MaskedModels.mask_virtual_readers('NoSuchModel')
        assert_nil PermissionForge::MaskedModels.mask_virtual_readers('PfVirtualPlainProfile')
        assert_not PermissionForge::Concerns::MaskedAttributes.applied?(::PfVirtualPlainProfile)
        assert_equal 'plain', ::PfVirtualPlainProfile.new.display_name
      end
    end
  end
end
