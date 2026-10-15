require 'test_helper'

module PermissionForge
  module Admin
    # Rails 8's `bin/rails generate authentication` names the user's email
    # column `email_address` (there is no `email`). Labels, people search, bulk
    # matching and the profile must find the email there too.
    class EmailAddressPeopleTest < ActiveSupport::TestCase
      include InstallTemplates

      class Rails8Person < ActiveRecord::Base
        self.table_name = 'pf_rails8_people'
        self.primary_key = 'id' # MySQL does not list a temporary table's key in information_schema
      end

      # A user table with both columns (a host halfway through a rename).
      class TwoEmailPerson < ActiveRecord::Base
        self.table_name = 'pf_two_email_people'
        self.primary_key = 'id'
      end

      Config = Struct.new(:user_model, :user_label_formatter, :user_list, keyword_init: true)
      BothEmails = Struct.new(:id, :email, :email_address)
      EmailAddressOnly = Struct.new(:id, :email_address)

      setup do
        connection = ActiveRecord::Base.connection
        # Temporary: on MySQL, DDL on a regular table commits the test's transaction.
        connection.create_table(:pf_rails8_people, temporary: true) { |t| t.string :email_address }
        connection.create_table :pf_two_email_people, temporary: true do |t|
          t.string :email
          t.string :email_address
        end
        [Rails8Person, TwoEmailPerson].each(&:reset_column_information)
        @bob = Rails8Person.create!(email_address: 'bob@acme.test')
        @ana = Rails8Person.create!(email_address: 'ana@acme.test')
      end

      teardown do
        %i[pf_rails8_people pf_two_email_people].each do |table|
          ActiveRecord::Base.connection.drop_table table, temporary: true, if_exists: true
        end
      end

      def label(person)
        PersonLabel.new(person, configuration: Config.new)
      end

      def matcher(model)
        BulkPeopleMatcher.new(configuration: Config.new(user_model: model, user_list: model.order(:id)))
      end

      def unassigned_set
        set = create_permission_set
        set.define_singleton_method(:permission_set_users) { PermissionForge::PermissionSetUser.none }
        set
      end

      test 'EMAIL_ATTRIBUTES lists email, then email_address' do
        assert_equal %i[email email_address], PersonLabel::EMAIL_ATTRIBUTES
      end

      test 'the label shows the email_address when there is no name' do
        assert_equal 'bob@acme.test', label(@bob).name
        assert_equal 'bob@acme.test', label(@bob).email
        assert_nil label(@bob).secondary
        assert_includes label(@bob).search_text, 'bob@acme.test'
      end

      test 'the email_address shows under a name' do
        person = Struct.new(:id, :name, :email_address).new(1, 'Bob Builder', 'bob@acme.test')

        assert_equal 'Bob Builder', label(person).name
        assert_equal 'bob@acme.test', label(person).secondary
        assert_equal 'bob builder bob@acme.test', label(person).search_text
      end

      test 'the email_address is read raw, past a reader that masks it' do
        @bob.define_singleton_method(:email_address) { 'b**@acme.test' }

        assert_equal 'bob@acme.test', label(@bob).email
      end

      test 'email wins over email_address; a blank email falls through' do
        assert_equal 'new@acme.test', label(BothEmails.new(1, 'new@acme.test', 'old@acme.test')).email
        assert_equal 'old@acme.test', label(BothEmails.new(1, ' ', 'old@acme.test')).email
      end

      test 'people search finds an email_address in SQL' do
        found = PeopleCandidates::Relation.new(Rails8Person.order(:id)).search('bob@acme').take(0, 10)

        assert_equal [@bob], found
      end

      test 'people search finds an email_address in an array resolver' do
        people = [EmailAddressOnly.new(1, 'bob@acme.test'), EmailAddressOnly.new(2, 'ana@acme.test')]
        found = PeopleCandidates.wrap(people, configuration: Config.new).search('bob@acme').take(0, 10)

        assert_equal [people.first], found
      end

      test 'bulk paste matches an email_address, case-insensitively' do
        result = matcher(Rails8Person).call(text: "BOB@acme.test\nana@acme.test\nnobody@acme.test", user_ids: [],
                                            permission_set: unassigned_set)

        assert_equal [@bob, @ana], result.to_assign
        assert_equal ['nobody@acme.test'], result.not_found
      end

      test 'bulk paste matches either column when the table has both' do
        old_column = TwoEmailPerson.create!(email: nil, email_address: 'old@acme.test')
        new_column = TwoEmailPerson.create!(email: 'new@acme.test', email_address: nil)

        result = matcher(TwoEmailPerson).call(text: 'old@acme.test, new@acme.test', user_ids: [],
                                              permission_set: unassigned_set)

        assert_equal [old_column, new_column], result.to_assign
        assert_empty result.not_found
      end

      test 'the generated profile_builder fills email from email_address' do
        profile = install_template_configuration.profile_builder.call(@bob)

        assert_equal({ id: @bob.id, uuid: nil, name: nil, email: 'bob@acme.test' }, profile)
      end

      test 'the generated profile_builder still prefers email' do
        person = BothEmails.new(1, 'new@acme.test', 'old@acme.test')

        assert_equal 'new@acme.test', install_template_configuration.profile_builder.call(person)[:email]
      end

      test 'the generated initializer reads every email attribute' do
        template = render_install_template('initializer.rb.tt')

        PersonLabel::EMAIL_ATTRIBUTES.each { |attr| assert_includes template, "user.try(:#{attr})" }
      end

      test 'the default profile_builder fills email from email_address and still prefers email' do
        builder = Configuration.new.profile_builder

        assert_equal 'bob@acme.test', builder.call(@bob)[:email]
        assert_equal 'new@acme.test', builder.call(BothEmails.new(1, 'new@acme.test', 'old@acme.test'))[:email]
        assert_nil builder.call(Struct.new(:id).new(1))[:email]
      end
    end
  end
end
