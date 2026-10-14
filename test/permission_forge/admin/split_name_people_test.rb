require 'test_helper'

module PermissionForge
  module Admin
    # Host apps whose users store first/last name in `firstname`/`lastname`
    # columns (no `name` column) must still be searchable and matchable by name.
    class SplitNamePeopleTest < ActiveSupport::TestCase
      class SplitPerson < ActiveRecord::Base
        self.table_name = 'pf_split_people'
        self.primary_key = 'id' # MySQL does not list a temporary table's key in information_schema

        def name = "#{firstname} #{lastname}"
      end

      Config = Struct.new(:user_model, :user_label_formatter, :user_list, keyword_init: true)

      setup do
        # Temporary: on MySQL, DDL on a regular table commits the test's transaction.
        ActiveRecord::Base.connection.create_table :pf_split_people, temporary: true do |t|
          t.string :firstname
          t.string :lastname
          t.string :email
        end
        SplitPerson.reset_column_information
        @ana = SplitPerson.create!(firstname: 'Ana', lastname: 'Krasniqi', email: 'ana@acme.test')
        @bo = SplitPerson.create!(firstname: 'Bo', lastname: 'Berisha', email: 'bo@acme.test')
      end

      teardown do
        ActiveRecord::Base.connection.drop_table :pf_split_people, temporary: true, if_exists: true
      end

      def search(query)
        PeopleCandidates::Relation.new(SplitPerson.order(:id)).search(query).take(0, 10)
      end

      test 'searches first and last name columns, across words' do
        assert_equal [@ana], search('krasniqi')
        assert_equal [@ana], search('ana kras')
        assert_equal [@bo], search('bo@acme')
        assert_empty search('ana berisha')
      end

      test 'bulk matching finds "First Last" against split columns' do
        set = create_permission_set
        set.define_singleton_method(:permission_set_users) { PermissionForge::PermissionSetUser.none }
        matcher = BulkPeopleMatcher.new(configuration: Config.new(user_model: SplitPerson, user_list: SplitPerson.order(:id)))

        result = matcher.call(text: "Ana Krasniqi\nbo@acme.test\nNo Body", user_ids: [], permission_set: set)

        assert_equal [@ana, @bo], result.to_assign
        assert_equal ['No Body'], result.not_found
      end

      test 'labels compose firstname/lastname when there is no name' do
        person = Struct.new(:id, :firstname, :lastname).new(1, 'Ana', 'Krasniqi')

        assert_equal 'Ana Krasniqi', PersonLabel.new(person, configuration: Config.new).name
      end
    end
  end
end
