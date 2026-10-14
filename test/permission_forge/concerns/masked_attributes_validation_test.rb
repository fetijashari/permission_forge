# frozen_string_literal: true

require 'test_helper'

# A masked model with validations on guarded columns. Its own Resource name,
# so no dummy model is touched.
class PfValidatedCustomer < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  EMAIL = /\A[a-z0-9.+_-]+@[a-z0-9.-]+\z/i

  validates :name, presence: true
  validates :email, presence: true, format: { with: EMAIL }, uniqueness: true
  validates :domain, presence: true
end

# Validations whose errors carry the value: a custom %{value} message, an
# i18n override (below, scoped to this model), inclusion, numericality and a
# memoised derived reader.
class PfLeakCustomer < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  validates :email, format: { with: /@acme\.test\z/, message: '%{value} is not an acme address' }, uniqueness: true # rubocop:disable Style/FormatStringToken
  validates :domain, inclusion: { in: %w[acme.test] }, allow_nil: true
  validates :supplier_id, numericality: { less_than: 100 }, allow_nil: true
  validates :contact, presence: true

  def contact = (@contact ||= "#{name} <#{email}>")
end

# Numeric checks on columns the reader sees masked. Rails' numericality
# validator reads the attribute again with read_attribute after
# read_attribute_for_validation; a custom validate block after it reads the
# getter.
class PfNumericCustomer < ApplicationRecord
  self.table_name = 'customers'

  include PermissionForge::Concerns::MaskedAttributes

  class << self
    def seen = (@seen ||= [])
  end

  validates :supplier_id, numericality: { less_than: 10 }
  validates :account_id, comparison: { less_than: 10 }, allow_nil: true
  validate { self.class.seen << supplier_id }
end

# Rails' %{value} interpolation is what is under test.
LEAK_DOMAIN_MESSAGE = { inclusion: '%{value} is not allowed' }.freeze # rubocop:disable Style/FormatStringToken
I18n.backend.store_translations(:en, activerecord: { errors: { models: { pf_leak_customer: { attributes: { domain: LEAK_DOMAIN_MESSAGE } } } } })

module PermissionForge
  module Concerns
    # Validations read the stored values (read_attribute_for_validation):
    # they are the model's own logic, not output. A hidden or masked value
    # must neither fail a check the stored value passes (nobody signed in
    # under :hide; a user who reads `s***@acme.test` or nothing at all) nor
    # pass one the stored value fails (uniqueness against a mask). Everything
    # else still reads masked.
    class MaskedAttributesValidationTest < ActiveSupport::TestCase
      setup do
        Current.user = nil
        set = create_permission_set(name: 'Validated readers')
        resource = create_resource(permission_set: set, name: 'PfValidatedCustomer', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'name', label: 'Name', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'email', label: 'Email', read_access: true,
                              mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: resource, name: 'domain', label: 'Domain', read_access: false)
        @reader = create_user
        create_permission_set_user(user: @reader, permission_set: set)
        @stored = PfValidatedCustomer.create!(name: 'Acme', email: 'sales@acme.test', domain: 'acme.test')
      end

      teardown { Current.user = nil }

      def stored_email(record) = record.read_attribute_before_type_cast(:email)

      test 'with nobody signed in under :hide a masked model is created and updated' do
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide

        created = PfValidatedCustomer.create!(name: 'Beta', email: 'info@beta.test', domain: 'beta.test')
        assert_nil created.email, 'the getter still hides'

        record = PfValidatedCustomer.find(@stored.id)
        record.update!(name: 'Acme Ltd')

        assert_equal 'Acme Ltd', record.read_attribute_before_type_cast(:name)
        assert_equal 'sales@acme.test', stored_email(record.reload), 'the stored value is untouched'
        assert_nil record.email
        assert_equal %w[id], record.as_json.keys
      end

      test 'a signed-in user who reads a masked and a hidden column can save a record' do
        Current.user = @reader
        record = PfValidatedCustomer.find(@stored.id)
        assert_equal 's***@acme.test', record.email
        assert_nil record.domain

        record.update!(name: 'Acme Ltd')

        assert_equal 'sales@acme.test', stored_email(record.reload)
        assert_equal 'acme.test', record.read_attribute_before_type_cast(:domain)
      end

      test 'uniqueness is checked against the stored value, not the mask' do
        Current.user = @reader
        duplicate = PfValidatedCustomer.new(name: 'Copy', email: 'sales@acme.test', domain: 'copy.test')

        assert_not duplicate.valid?
        assert_includes duplicate.errors[:email], 'has already been taken'
      end

      test 'a stored value that is invalid still fails, whatever the reader sees' do
        Current.user = @reader
        invalid = PfValidatedCustomer.new(name: 'Bad', email: 'not an email', domain: 'bad.test')

        assert_not invalid.valid?
        assert_includes invalid.errors[:email], 'is invalid'
      end

      test 'nothing but validation reads the stored value' do
        Current.user = @reader
        record = PfValidatedCustomer.find(@stored.id)
        assert record.valid?

        assert_equal 's***@acme.test', record.read_attribute_for_validation(:email),
                     'outside the validators (a message rendered later) it is the getter'
        assert_equal 's***@acme.test', record.email
        assert_equal 's***@acme.test', record.read_attribute(:email)
        assert_equal 's***@acme.test', record[:email]
        assert_equal 's***@acme.test', record.as_json['email']
        assert_nil record.domain
        assert_not_includes record.attributes.keys, 'domain'
      end

      test 'a validation that raises leaves the record masked' do
        Current.user = @reader
        record = PfValidatedCustomer.find(@stored.id)
        record.define_singleton_method(:name) { raise ArgumentError, 'boom' }

        assert_raises(ArgumentError) { record.valid? }
        assert_equal 's***@acme.test', record.email
        assert_equal 's***@acme.test', record.read_attribute_for_validation(:email)
      end
    end

    # The values validations read never reach the user who reads them masked or
    # hidden: an error's value: (errors.details, %{value} in messages and
    # i18n) is what that user's getter returns, or absent when the column is
    # hidden; and only the attribute being validated is read as stored, so a
    # derived reader memoises what the user sees.
    class MaskedAttributesValidationValueTest < ActiveSupport::TestCase
      RAW_EMAIL = 'secret.person@other.test'

      setup do
        Current.user = nil
        set = create_permission_set(name: 'Leak readers')
        resource = create_resource(permission_set: set, name: 'PfLeakCustomer', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'name', label: 'Name', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'email', label: 'Email', read_access: true,
                              mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: resource, name: 'domain', label: 'Domain', read_access: false)
        create_resource_field(resource: resource, name: 'supplier_id', label: 'Supplier', read_access: false)
        @reader = create_user
        create_permission_set_user(user: @reader, permission_set: set)
        PfLeakCustomer.insert_all!([{ name: 'Acme 2', email: RAW_EMAIL, domain: 'hidden-domain.test', supplier_id: 500,
                                      created_at: Time.current, updated_at: Time.current }])
        @id = PfLeakCustomer.unscoped.maximum(:id)
      end

      teardown { Current.user = nil }

      def invalid_record
        record = PfLeakCustomer.find(@id)
        assert_not record.valid?
        record
      end

      def assert_no_stored_value(record)
        text = [record.errors.full_messages, record.errors.details, record.errors.as_json, record.errors.to_hash].inspect
        assert_not_includes text, RAW_EMAIL
        assert_not_includes text, 'hidden-domain.test'
        assert_not_includes text, '500'
      end

      test 'validations judge the stored values' do
        Current.user = @reader
        record = invalid_record

        assert_equal %i[email domain supplier_id].sort, record.errors.attribute_names.sort
      end

      test 'a signed-in reader sees masked values in messages and details, and nothing of hidden columns' do
        Current.user = @reader
        record = invalid_record

        assert_includes record.errors.full_messages, 'Email s***@other.test is not an acme address'
        assert_equal 's***@other.test', record.errors.details[:email].first[:value]
        assert_not record.errors.details[:domain].first.key?(:value), 'inclusion on a hidden column'
        assert_not record.errors.details[:supplier_id].first.key?(:value), 'numericality on a hidden column'
        assert_includes record.errors[:domain], ' is not allowed', 'the i18n message reads the hidden getter'
        assert_no_stored_value(record)
      end

      test 'uniqueness reports the value the reader sees' do
        Current.user = @reader
        duplicate = PfLeakCustomer.new(name: 'Copy', email: RAW_EMAIL)

        assert_not duplicate.valid?
        taken = duplicate.errors.details[:email].find { |detail| detail[:error] == :taken }
        assert_equal 's***@other.test', taken[:value]
        assert_no_stored_value(duplicate)
      end

      test 'nobody signed in under :hide sees no values at all' do
        PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide
        record = invalid_record

        assert_equal %i[email domain supplier_id].sort, record.errors.attribute_names.sort
        assert(record.errors.details.values.flatten.none? { |detail| detail.key?(:value) })
        assert_no_stored_value(record)
      end

      test 'a memoised derived reader keeps what the reader sees' do
        Current.user = @reader
        record = invalid_record

        assert_equal 'Acme 2 <s***@other.test>', record.contact
      end
    end

    # A numeric column the reader sees masked is judged on its stored value
    # by numericality (which reads it again with read_attribute) and
    # comparison, while the errors still show the mask and every other read
    # is masked.
    class MaskedAttributesValidationNumericTest < ActiveSupport::TestCase
      setup do
        Current.user = nil
        set = create_permission_set(name: 'Numeric readers')
        resource = create_resource(permission_set: set, name: 'PfNumericCustomer', read_access: true, edit_access: true)
        %w[supplier_id account_id].each do |column|
          create_resource_field(resource: resource, name: column, label: column.humanize, read_access: true,
                                mask_access: true, mask_strategy: 'full')
        end
        @reader = create_user
        create_permission_set_user(user: @reader, permission_set: set)
        PfNumericCustomer.seen.clear
      end

      teardown { Current.user = nil }

      def stored(supplier_id:, account_id: nil)
        PfNumericCustomer.insert_all!([{ name: 'Numbers', supplier_id: supplier_id, account_id: account_id,
                                         created_at: Time.current, updated_at: Time.current }])
        PfNumericCustomer.find(PfNumericCustomer.unscoped.maximum(:id))
      end

      test 'a stored number that passes passes for a reader who sees it masked' do
        Current.user = @reader
        record = stored(supplier_id: 5, account_id: 3)

        assert_predicate record, :valid?, record.errors.details.inspect
        assert_not_equal 5, record.supplier_id, 'the reader sees it masked'
      end

      test 'a stored number that fails reports the check it fails, with the masked value' do
        Current.user = @reader
        record = stored(supplier_id: 4242, account_id: 77)

        assert_not record.valid?
        assert_equal [:less_than], record.errors.details[:supplier_id].pluck(:error)
        assert_equal [:less_than], record.errors.details[:account_id].pluck(:error)
        text = [record.errors.full_messages, record.errors.details].inspect
        assert_not_includes text, '4242'
        assert_not_includes text, '77'
      end

      test 'nothing but the validator reads the stored number' do
        Current.user = @reader
        record = stored(supplier_id: 4242)
        record.valid?

        assert_equal 1, PfNumericCustomer.seen.size
        assert_not_equal 4242, PfNumericCustomer.seen.first, 'a validate block after it reads the getter'
        assert_not_equal 4242, record.supplier_id
        assert_not_equal 4242, record.read_attribute(:supplier_id)
      end
    end
  end
end
