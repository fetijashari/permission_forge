require 'test_helper'

module PermissionForge
  module Admin
    # A host whose user model encrypts its name and email (Active Record
    # encryption): the columns hold ciphertext JSON (`{"p":"…","h":{"iv":…}}`).
    # The admin read them raw — people labels showed the JSON, the people
    # search LIKE-matched it (`iv` found everyone) and bulk matching compared
    # it with the pasted text (nobody). Review round 7 (E#73 siblings):
    #
    # - Admin::PersonLabel reads an encrypted attribute decrypted (past
    #   MaskedAttributes still: the attribute type, not the reader);
    # - PeopleCandidates leaves encrypted columns out of the SQL search; a
    #   deterministically encrypted one matches the whole query exactly;
    # - BulkPeopleMatcher matches a deterministically encrypted email or name
    #   exactly, and never LIKEs or lower-cases ciphertext.
    class EncryptedPeopleTest < ActiveSupport::TestCase
      class EncryptedPerson < ActiveRecord::Base
        self.table_name = 'pf_encrypted_people'
        self.primary_key = 'id' # MySQL does not list a temporary table's key in information_schema

        encrypts :name
        encrypts :email, deterministic: true
      end

      Config = Struct.new(:user_model, :user_label_formatter, :user_list, keyword_init: true)

      setup do
        # Temporary: on MySQL, DDL on a regular table commits the test's transaction.
        ActiveRecord::Base.connection.create_table :pf_encrypted_people, temporary: true do |t|
          t.text :name
          t.text :email
        end
        EncryptedPerson.reset_column_information
        PermissionForge::SchemaRead.reset!
        @ana = EncryptedPerson.create!(name: 'Ana Krasniqi', email: 'ana@acme.test')
        @bo = EncryptedPerson.create!(name: 'Bo Berisha', email: 'bo@acme.test')
      end

      teardown do
        ActiveRecord::Base.connection.drop_table :pf_encrypted_people, temporary: true, if_exists: true
        PermissionForge::SchemaRead.reset!
      end

      def search(query)
        PeopleCandidates::Relation.new(EncryptedPerson.order(:id)).search(query).take(0, 10)
      end

      test 'a label reads the name and email decrypted, never the ciphertext' do
        label = PersonLabel.new(@ana.reload, configuration: Config.new)

        assert_equal 'Ana Krasniqi', label.name
        assert_equal 'ana@acme.test', label.email
        assert_equal 'ana@acme.test', PersonLabel.raw_value(@ana, :email)
      end

      test 'the search never matches the ciphertext' do
        %w[iv p at {].each { |query| assert_empty search(query), query }
        assert_empty search('ana'), 'a non-deterministic name cannot be searched in SQL'
      end

      test 'a deterministically encrypted email matches the whole query exactly' do
        assert_equal [@ana], search('ana@acme.test')
        assert_equal [@bo], search(@bo.id.to_s)
      end

      test 'bulk matching finds a deterministically encrypted email exactly, and nobody by an encrypted name' do
        set = create_permission_set
        set.define_singleton_method(:permission_set_users) { PermissionForge::PermissionSetUser.none }
        matcher = BulkPeopleMatcher.new(configuration: Config.new(user_model: EncryptedPerson, user_list: EncryptedPerson.order(:id)))

        result = matcher.call(text: "ana@acme.test\nBo Berisha", user_ids: [], permission_set: set)

        assert_equal [@ana], result.to_assign
        assert_equal ['Bo Berisha'], result.not_found
      end
    end
  end
end
