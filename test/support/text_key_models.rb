# String-keyed stand-ins for a host whose users or tenants have UUID primary
# keys. SQLite has no uuid type; ActiveRecord truncates a string key written
# to an integer column in exactly the same way ('1aaa…' and '1bbb…' both
# become 1), which is the behaviour these models exist to test.
ActiveRecord::Base.connection.create_table(:text_key_users, id: :string, force: true) do |t|
  t.string :name
  t.string :email
  t.timestamps
end

ActiveRecord::Base.connection.create_table(:text_key_tenants, id: :string, force: true) do |t|
  t.string :name
  t.timestamps
end

class TextKeyUser < ActiveRecord::Base
  include PermissionForge::Concerns::PermissionedUser
end

class TextKeyTenant < ActiveRecord::Base
end
