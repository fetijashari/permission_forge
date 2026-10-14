require 'test_helper'
require_relative '../virtual_field_models'

# store_accessor on a column that holds the hash itself (as a json/jsonb
# column does): unlike `store`, its value is nil while nothing is stored.
class PfStoreSerializedProfile < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  serialize :domain, coder: JSON
  store_accessor :domain, :theme
end

# A store declared on an alias of its column.
class PfStoreAliasedProfile < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  store :domain, coder: JSON
  alias_attribute :settings, :domain
  store_accessor :settings, :theme
end

# A store on an attribute that is not a column: its getter is not masked
# (virtual masking is off), so Rails reads it as usual.
class PfStoreVirtualProfile < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  attribute :prefs, :json, default: -> { { 'vtheme' => 'dark' } }
  store_accessor :prefs, :vtheme
end

module PermissionForge
  module Concerns
    # Store accessors on a model with MaskedAttributes: a key is never read
    # through a store column the user may not read, and reading or writing a
    # key never replaces the stored hash. Virtual-reader masking is off here —
    # this is about the store column itself.
    class MaskedStoreAccessTest < ActiveSupport::TestCase
      setup do
        @config = PermissionForge.configuration
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'PfVirtualProfile', read_access: true)
        @config.unconfigured_field_strategy = :pass_through
        @id = ::PfVirtualProfile.create!(uuid: SecureRandom.uuid, name: 'Acme Corp', email: 'contact@acme.com',
                                         theme: 'dark', domain_color: 'teal').id
        Current.user = @user
      end

      def configure(name, **flags)
        create_resource_field(resource: @resource, name: name, label: name.humanize, **flags)
        @user.regenerate_permissions
      end

      def profile
        ::PfVirtualProfile.find(@id)
      end

      # The stored hash, read past every getter.
      def stored
        value = ::PfVirtualProfile.connection.select_value("SELECT domain FROM customers WHERE id = #{@id.to_i}")
        value = JSON.parse(value) while value.is_a?(String)
        value
      end

      test 'a key of a readable store column is read as usual' do
        configure('domain', read_access: true)

        assert_equal 'dark', profile.theme
        assert_equal 'teal', profile.domain_color
      end

      test 'a key of a hidden store column gives the hidden value' do
        configure('domain', read_access: false)

        assert_nil profile.theme
        assert_nil profile.domain_color
      end

      test 'a key of a masked store column gives the hidden value, not a piece of the mask' do
        configure('domain', read_access: true, mask_access: true, mask_strategy: 'full')

        assert_nil profile.theme
      end

      test 'a key of an unconfigured store column follows unconfigured_field_strategy' do
        assert_equal 'dark', profile.theme

        @config.unconfigured_field_strategy = :block
        assert_nil profile.theme

        @config.unconfigured_field_strategy = :mask_all
        assert_nil profile.theme
      end

      # Rails would otherwise see nil where it expects the hash and assign {}.
      test 'reading a key of a hidden store column leaves the record clean and the stored hash intact' do
        configure('domain', read_access: false)
        record = profile

        record.theme
        record.domain_color

        assert_not record.changed?, "reading dirtied #{record.changed.inspect}"
        record.save!
        assert_equal({ 'theme' => 'dark', 'color' => 'teal' }, stored)
      end

      test 'the same holds for a masked store column' do
        configure('domain', read_access: true, mask_access: true, mask_strategy: 'full')
        record = profile

        record.theme

        assert_not record.changed?
        record.update!(name: 'Renamed')
        assert_equal({ 'theme' => 'dark', 'color' => 'teal' }, stored)
      end

      test 'writing a key of a hidden store column keeps the other keys' do
        configure('domain', read_access: false)
        record = profile

        record.theme = 'light'
        record.save!

        assert_equal({ 'theme' => 'light', 'color' => 'teal' }, stored)
      end

      test 'writing a key of a masked store column keeps the other keys' do
        configure('domain', read_access: true, mask_access: true, mask_strategy: 'full')
        record = profile

        record.domain_color = 'red'
        record.save!

        assert_equal({ 'theme' => 'dark', 'color' => 'red' }, stored)
      end

      test 'writing a key reveals nothing: the column and its keys stay hidden' do
        configure('domain', read_access: false)
        record = profile

        record.theme = 'light'

        assert_nil record.domain
        assert_nil record.theme
        assert_nil record.domain_color
        assert_nil record.read_attribute(:domain)
      end

      test 'the raw read covers only the store column, and ends with the block even when it raises' do
        configure('domain', read_access: false)
        configure('email', read_access: false)
        record = profile

        assert_raises(ArgumentError) do
          record.send(:pf_with_raw_store_column, :domain) do
            assert_equal 'dark', record.domain['theme']
            assert_nil record.email, 'other columns stay guarded'
            raise ArgumentError, 'boom'
          end
        end

        assert_empty PermissionForge::ExecutionState[MaskedAttributes::StoreAccess::RAW_STORE_KEY]
        assert_nil record.domain
      end

      test 'a copy made while a key is written, and another thread, never read the column raw' do
        configure('domain', read_access: false)
        record = profile

        user = @user
        record.send(:pf_with_raw_store_column, :domain) do
          assert_nil record.dup.domain
          assert_nil record.clone.domain
          # Current is per thread: the other thread has to be the same user.
          other_thread = Thread.new do
            Current.user = user
            record.domain
          end
          assert_nil other_thread.value
        end
      end

      # --- a store whose value is nil while nothing is stored --------------------

      def serialized(name, **flags)
        resource = create_resource(permission_set: @set, name: 'PfStoreSerializedProfile', read_access: true)
        create_resource_field(resource: resource, name: name, label: name.humanize, **flags)
        @user.regenerate_permissions
        ::PfStoreSerializedProfile.connection.execute("UPDATE customers SET domain = NULL WHERE id = #{@id.to_i}")
        ::PfStoreSerializedProfile.find(@id)
      end

      test 'a hidden store column that holds nothing is still hidden, not handed to Rails' do
        record = serialized('domain', read_access: false)

        assert_nil record.theme
        assert_not record.changed?, "reading dirtied #{record.changed.inspect}"
        assert_nil ::PfStoreSerializedProfile.new.theme
      end

      test 'a masked store column that holds nothing gives the hidden value' do
        @config.hidden_attribute_value = '[hidden]'
        record = serialized('domain', read_access: true, mask_access: true, mask_strategy: 'full')

        assert_equal '[hidden]', record.theme
        assert_not record.changed?
      ensure
        @config.hidden_attribute_value = nil
      end

      test 'a hidden store column that holds nothing takes a key' do
        record = serialized('domain', read_access: false)

        record.theme = 'light'
        record.save!

        assert_equal({ 'theme' => 'light' }, stored)
      end

      test 'a readable store column that holds nothing reads as usual' do
        record = serialized('domain', read_access: true)

        assert_nil record.theme
        record.theme = 'light'
        record.save!

        assert_equal({ 'theme' => 'light' }, stored)
      end

      # --- stores this concern does not mask ---------------------------------------

      test 'a store declared on an alias of its column reads and writes like the column' do
        resource = create_resource(permission_set: @set, name: 'PfStoreAliasedProfile', read_access: true)
        record = ::PfStoreAliasedProfile.find(@id)
        assert_equal 'dark', record.theme

        Current.user = nil
        assert_equal 'dark', ::PfStoreAliasedProfile.find(@id).theme

        Current.user = @user
        create_resource_field(resource: resource, name: 'domain', label: 'Domain', read_access: false)
        @user.regenerate_permissions
        record = ::PfStoreAliasedProfile.find(@id)

        assert_nil record.theme
        record.theme = 'light'
        record.save!
        assert_equal({ 'theme' => 'light', 'color' => 'teal' }, stored)
      end

      test 'a store on an attribute that is not a column is left to Rails' do
        create_resource(permission_set: @set, name: 'PfStoreVirtualProfile', read_access: true)
        @config.unconfigured_field_strategy = :block
        @user.regenerate_permissions
        record = ::PfStoreVirtualProfile.find(@id)

        assert_equal 'dark', record.vtheme
        record.vtheme = 'light'
        assert_equal 'light', record.vtheme
      end

      test 'a store column that is empty in the database still takes a key' do
        ::PfVirtualProfile.connection.execute("UPDATE customers SET domain = NULL WHERE id = #{@id.to_i}")
        configure('domain', read_access: false)
        record = profile

        record.theme = 'light'
        record.save!

        assert_equal({ 'theme' => 'light' }, stored)
      end

      test 'without a current user nothing changes' do
        configure('domain', read_access: false)
        Current.user = nil
        record = profile

        assert_equal 'dark', record.theme
        record.theme = 'light'
        record.save!

        assert_equal({ 'theme' => 'light', 'color' => 'teal' }, stored)
      end
    end
  end
end
