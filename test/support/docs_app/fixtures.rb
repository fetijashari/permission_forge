# frozen_string_literal: true

module DocsApp
  # The host rows of the docs app (the tables the generators' migrations
  # create, the people of the recordings) and, once PermissionForge is
  # installed, the Permission Sets the scenarios need. Named apart from the
  # sets the documents create ("Sales Team").
  #
  #   Alice  Account managers   every Customer, every field, edits all (view_all, modify_all); an admin
  #   Bob    Sales reps         her own customers (a rule), name editable, email masked
  #   Carol  Sales reps         the same set; owns the customers Bob may not open
  #   Dave   —                  signed up, holds no Permission Set
  #   Erin   Auditors           a rule but no read on the resource (permission_scoped still answers rows)
  module Fixtures
    PEOPLE = { alice: 'Alice Admin', bob: 'Bob Sales', carol: 'Carol Sales', dave: 'Dave Newcomer', erin: 'Erin Audit' }.freeze
    CUSTOMERS = [['Acme', :bob], ['Globex', :carol], ['Initech', :carol], ['Umbrella', :erin], ['Stark', :carol]].freeze

    module_function

    def email(name) = "#{name}@example.com"

    # Users by email, read again on every call: a reload replaces the classes.
    def person(name) = User.find_by!(email_address: email(name))

    def customer(name) = PermissionForge.without_permission_scope { Customer.find_by!(name: name) }

    # The tables the authentication and scaffold generators' migrations create
    # (users with a name and an admin flag for the docs' Admin::BaseController).
    def host_tables!
      connection = ActiveRecord::Base.connection
      users_table!(connection)
      connection.create_table(:sessions) do |t|
        t.references :user, null: false, foreign_key: true
        t.string :ip_address
        t.string :user_agent
        t.timestamps
      end
      customers_table!(connection)
    end

    def users_table!(connection)
      connection.create_table(:users) do |t|
        t.string :email_address, null: false
        t.string :password_digest, null: false
        t.string :name
        t.boolean :admin, null: false, default: false
        t.timestamps
      end
      connection.add_index(:users, :email_address, unique: true)
    end

    def customers_table!(connection)
      connection.create_table(:customers) do |t|
        t.string :name
        t.string :email
        t.string :phone
        t.string :status
        t.text :notes
        t.references :owner, null: false, foreign_key: { to_table: :users }
        t.timestamps
      end
    end

    def people!
      ActiveModel::SecurePassword.min_cost = true
      PEOPLE.each do |key, name|
        User.create!(email_address: email(key), password: PASSWORD, name: name, admin: key == :alice)
      end
      CUSTOMERS.each do |name, owner|
        Customer.create!(name: name, email: "#{name.downcase}@example.test", phone: '+1 555 0100', status: 'active',
                         notes: "Notes about #{name}", owner: person(owner))
      end
    end

    def permissions!
      account_managers!
      sales_reps!
      auditors!
    end

    def account_managers!
      set = PermissionForge::PermissionSet.create!(name: 'Account managers', is_active: true)
      resource = PermissionForge::Resource.create!(permission_set: set, name: 'Customer', read_access: true, create_access: true,
                                                   edit_access: true, delete_access: true, view_all: true, modify_all: true)
      PermissionForge::Services::ResourceFieldGenerator.call(resource: resource, grant_all: true)
      PermissionForge::PermissionSetUser.create!(permission_set: set, user: person(:alice))
    end

    def sales_reps!
      set = PermissionForge::PermissionSet.create!(name: 'Sales reps', is_active: true)
      resource = PermissionForge::Resource.create!(permission_set: set, name: 'Customer', read_access: true, create_access: true,
                                                   edit_access: true)
      PermissionForge::ResourceField.create!(resource: resource, name: 'name', label: 'Name', read_access: true, edit_access: true)
      PermissionForge::ResourceField.create!(resource: resource, name: 'email', label: 'Email', read_access: true,
                                             mask_access: true, mask_strategy: 'email')
      PermissionForge::PermissionSetRule.create!(permission_set: set, resource: resource, name: 'Own customers', field_name: 'owner_id',
                                                 operator: 'equal', field_value: 'current_user', include_nulls: false,
                                                 failure_message: 'Only your own customers')
      %i[bob carol].each { |name| PermissionForge::PermissionSetUser.create!(permission_set: set, user: person(name)) }
    end

    def auditors!
      set = PermissionForge::PermissionSet.create!(name: 'Auditors', is_active: true)
      resource = PermissionForge::Resource.create!(permission_set: set, name: 'Customer', read_access: false)
      PermissionForge::PermissionSetRule.create!(permission_set: set, resource: resource, name: 'Own customers', field_name: 'owner_id',
                                                 operator: 'equal', field_value: 'current_user', include_nulls: false)
      PermissionForge::PermissionSetUser.create!(permission_set: set, user: person(:erin))
    end
  end
end
