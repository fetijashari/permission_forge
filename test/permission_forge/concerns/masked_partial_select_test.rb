require 'test_helper'

# The same model twice on the dummy customers table: without the concern (what
# plain Rails does on the Rails version under test) and with it.
module PfPartialShape
  def self.included(base)
    base.table_name = 'customers'
    base.attribute :nickname, :string, default: 'Ace'
    base.store :domain, accessors: %i[theme], coder: JSON
    base.alias_attribute :mail, :email
  end

  def display_name
    "dn:#{read_attribute_before_type_cast('name')}"
  end
end

# Never give this one a Resource row: it must stay without the concern.
class PfPartialPlain < ApplicationRecord
  include PfPartialShape
end

class PfPartialProfile < ApplicationRecord
  include PfPartialShape
  include PermissionForge::Concerns::MaskedAttributes

  def self.extra_fields_for_permissions
    %w[display_name]
  end
end

module PermissionForge
  module Concerns
    # A record loaded with only some of its columns (`select(:id)`): reading or
    # writing a column that was not loaded behaves as it does on a model
    # without the concern — it raises where Rails raises, and never raises or
    # stays silent where Rails does the opposite.
    class MaskedPartialSelectTest < ActiveSupport::TestCase
      STORED = { 'theme' => 'dark', 'k' => 'v' }.freeze
      MISSING = ActiveModel::MissingAttributeError

      setup do
        @config = PermissionForge.configuration
        @config.unconfigured_field_strategy = :pass_through
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'PfPartialProfile', read_access: true, edit_access: true)
        configure('email', read_access: false)
        configure('name', read_access: true, mask_access: true, mask_strategy: 'full')
        @id = ::PfPartialProfile.create!(uuid: 'u-1', name: 'Acme Corp', email: 'contact@acme.com', theme: 'dark').id
        ::PfPartialProfile.connection.execute("UPDATE customers SET domain = '#{STORED.to_json}' WHERE id = #{@id.to_i}")
        Current.user = @user
      end

      teardown do
        @config.mask_virtual_attributes = false
      end

      def configure(name, **flags)
        create_resource_field(resource: @resource, name: name, label: name.humanize, edit_access: flags[:read_access], **flags)
        @user.regenerate_permissions
      end

      def partial(klass = ::PfPartialProfile, *columns)
        klass.select(:id, *columns).find(@id)
      end

      def stored(column)
        value = ::PfPartialProfile.connection.select_value("SELECT #{column} FROM customers WHERE id = #{@id.to_i}")
        column == 'domain' ? JSON.parse(value) : value
      end

      # What the block does with a record of `klass`: its value, or the error class.
      def outcome(klass, columns)
        yield partial(klass, *columns)
      rescue StandardError => e
        e.class
      end

      # Plain Rails raises MissingAttributeError here, so the model with the
      # concern must too — with a current user and without one.
      def assert_missing_like_rails(columns = [], &)
        assert_equal MISSING, outcome(::PfPartialPlain, columns, &), 'plain Rails does not raise here'
        assert_equal MISSING, outcome(::PfPartialProfile, columns, &), 'with a current user'
        Current.user = nil
        assert_equal MISSING, outcome(::PfPartialProfile, columns, &), 'without a current user'
      ensure
        Current.user = @user
      end

      # Plain Rails does not raise here; with no current user the model with
      # the concern gives the same answer, and with one it does not raise.
      def assert_quiet_like_rails(columns = [], &)
        expected = outcome(::PfPartialPlain, columns, &)

        assert_not_kind_of Class, expected, 'plain Rails raises here'
        assert_not_kind_of Class, outcome(::PfPartialProfile, columns, &), 'with a current user'
        Current.user = nil
        actual = outcome(::PfPartialProfile, columns, &)
        expected.nil? ? assert_nil(actual, 'without a current user') : assert_equal(expected, actual, 'without a current user')
      ensure
        Current.user = @user
      end

      # --- column getters -------------------------------------------------------

      test 'the getter of a column that was not loaded raises, whatever its level' do
        configure('domain', read_access: true)

        assert_missing_like_rails(&:email)  # hidden
        assert_missing_like_rails(&:name)   # masked
        assert_missing_like_rails(&:uuid)   # unconfigured
        assert_missing_like_rails(&:domain) # readable
        %i[email name].each { |reader| assert_missing_like_rails { |record| record.public_send(reader) } }
        assert_missing_like_rails(&:email?)
        assert_missing_like_rails(&:mail)
      end

      test 'the error is the one Rails raises' do
        rails = assert_raises(MISSING) { partial(::PfPartialPlain).email }
        error = assert_raises(MISSING) { partial.email }

        assert_equal "missing attribute 'email' for PfPartialProfile", error.message
        assert_equal rails.message.sub('PfPartialPlain', 'PfPartialProfile'), error.message
      end

      test 'loaded columns of a partial record are still guarded' do
        record = partial(::PfPartialProfile, :name, :email)

        assert_equal '********', record.name
        assert_nil record.email
        assert_raises(MISSING) { record.uuid }
      end

      test 'a hidden column of a fully loaded record still returns the hidden value' do
        record = ::PfPartialProfile.find(@id)

        assert_nil record.email
        assert_equal '********', record.name
        assert_not_includes record.as_json.values, 'contact@acme.com'
      end

      # --- read_attribute / [] --------------------------------------------------

      test '[] raises and read_attribute gives nil for a column that was not loaded, as on any model' do
        assert_missing_like_rails { |record| record[:email] }
        assert_missing_like_rails { |record| record[:uuid] }
        assert_quiet_like_rails { |record| record.read_attribute(:email) }
        assert_quiet_like_rails { |record| record.read_attribute(:uuid) }
        assert_nil partial.read_attribute(:uuid)
      end

      # --- attributes and serialization -------------------------------------------

      test 'attributes and as_json list the loaded attributes only and do not raise' do
        assert_quiet_like_rails(&:attributes)
        assert_quiet_like_rails(&:as_json)
        assert_quiet_like_rails([:uuid]) { |record| record.attributes.except('id') }
        assert_quiet_like_rails { |record| record.serializable_hash(only: %i[email uuid]) }
        assert_quiet_like_rails { |record| record.send(:attribute_names_for_serialization) }

        assert_equal %w[id name nickname], partial(::PfPartialProfile, :name).attributes.keys
        assert_equal '********', partial(::PfPartialProfile, :name).as_json['name']
      end

      test 'serializing a column that was not loaded raises, as on any model' do
        assert_missing_like_rails { |record| record.read_attribute_for_serialization(:email) }
        assert_missing_like_rails { |record| record.read_attribute_for_serialization(:uuid) }
        assert_missing_like_rails { |record| record.serializable_hash(methods: [:uuid]) }
        assert_missing_like_rails { |record| record.as_json(methods: [:mail]) }
        assert_missing_like_rails { |record| record.slice(:uuid) }
        assert_quiet_like_rails([:uuid]) { |record| record.read_attribute_for_serialization(:uuid) }
      end

      # --- setters ----------------------------------------------------------------

      test 'assigning a column that was not loaded works, as on any model' do
        write = lambda do |record|
          record.uuid = 'u-2'
          record.save!
          stored('uuid')
        end

        assert_quiet_like_rails(&write)
        assert_equal 'u-2', write.call(partial)
      end

      # --- store accessors ----------------------------------------------------------

      test 'a store accessor on a store column that was not loaded raises and leaves the stored hash alone' do
        configure('domain', read_access: true)

        assert_missing_like_rails(&:theme)
        assert_missing_like_rails { |record| record.theme = 'light' }
        assert_missing_like_rails do |record|
          record.theme
        ensure
          record.save!
        end
        assert_missing_like_rails do |record|
          record.theme = 'light'
        ensure
          record.save!
        end

        assert_equal STORED, stored('domain')
      end

      test 'the same holds when the store column is hidden or masked for the user' do
        configure('domain', read_access: false)

        assert_missing_like_rails(&:theme)
        assert_missing_like_rails do |record|
          record.theme = 'light'
        ensure
          record.save!
        end

        assert_equal STORED, stored('domain')
      end

      test 'a store accessor on a loaded store column of a partial record works as before' do
        configure('domain', read_access: true)
        record = partial(::PfPartialProfile, :domain)

        assert_equal 'dark', record.theme

        record.theme = 'light'
        record.save!

        assert_equal STORED.merge('theme' => 'light'), stored('domain')
      end

      test 'a hidden store column that is loaded stays hidden and keeps its other keys' do
        configure('domain', read_access: false)
        record = partial(::PfPartialProfile, :domain)

        assert_nil record.theme
        assert_nil record.domain

        record.theme = 'light'
        record.save!

        assert_equal STORED.merge('theme' => 'light'), stored('domain')
      end

      # --- virtual readers ----------------------------------------------------------

      test 'virtual readers on a partial record answer as on any model' do
        assert_quiet_like_rails(&:nickname)
        assert_quiet_like_rails(&:display_name)
        assert_quiet_like_rails { |record| record[:nickname] }
        assert_quiet_like_rails { |record| record.as_json(methods: %i[display_name]) }
      end

      test 'masked virtual readers on a partial record neither raise nor reveal' do
        configure('nickname', read_access: false)
        configure('display_name', read_access: true, mask_access: true)
        @config.mask_virtual_attributes = :auto
        ::PfPartialProfile.pf_mask_virtual_readers(%w[nickname display_name])

        record = partial

        assert_nil record.nickname
        assert_equal '********', record.display_name
        assert_equal({ 'id' => @id, 'display_name' => '********' }, record.as_json(methods: %i[display_name nickname]))

        Current.user = nil

        assert_equal 'Ace', partial.nickname
        assert_equal 'dn:', partial.display_name
      end
    end
  end
end
