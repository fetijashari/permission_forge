user = User.create!(name: 'Admin User', email: 'admin@example.com', uuid: SecureRandom.uuid)
puts "Created user: #{user.name} (id: #{user.id})"

group = PermissionForge::PermissionSetGroup.create!(
  uuid: SecureRandom.uuid,
  name: 'Sales Team',
  description: 'Permissions for the sales department'
)
puts "Created group: #{group.name}"

ps1 = PermissionForge::PermissionSet.create!(
  uuid: SecureRandom.uuid,
  permission_set_group_id: group.id,
  name: 'Sales Rep Permissions',
  description: 'Standard access for sales representatives'
)
ps2 = PermissionForge::PermissionSet.create!(
  uuid: SecureRandom.uuid,
  name: 'Admin Permissions',
  description: 'Full access for administrators'
)
puts "Created permission sets: #{ps1.name}, #{ps2.name}"

PermissionForge::PermissionSetUser.create!(
  uuid: SecureRandom.uuid,
  permission_set_id: ps1.id,
  user_id: user.id
)
puts 'Assigned user to Sales Rep Permissions'

r1 = PermissionForge::Resource.create!(
  uuid: SecureRandom.uuid,
  permission_set_id: ps1.id,
  name: 'Customer',
  read_access: true,
  create_access: true,
  edit_access: true,
  delete_access: false,
  view_all: false,
  modify_all: false
)
r2 = PermissionForge::Resource.create!(
  uuid: SecureRandom.uuid,
  permission_set_id: ps1.id,
  name: 'Supplier',
  read_access: true,
  create_access: false,
  edit_access: false,
  delete_access: false,
  view_all: true
)
r3 = PermissionForge::Resource.create!(
  uuid: SecureRandom.uuid,
  permission_set_id: ps2.id,
  name: 'User',
  label: 'Users',
  read_access: true,
  create_access: true,
  edit_access: true,
  delete_access: true,
  view_all: true,
  modify_all: true
)
puts "Created resources: #{r1.name}, #{r2.name}, #{r3.name}"

%w[name email domain].each do |field|
  PermissionForge::ResourceField.create!(
    uuid: SecureRandom.uuid,
    resource_id: r1.id,
    name: field,
    label: field.humanize,
    read_access: true,
    edit_access: field != 'domain',
    mask_access: field == 'email',
    mask_strategy: field == 'email' ? 'email' : 'full'
  )
end
puts 'Created resource fields for Customer'

PermissionForge::PermissionSetRule.create!(
  uuid: SecureRandom.uuid,
  permission_set_id: ps1.id,
  resource_id: r1.id,
  name: 'Own customers only',
  field_name: 'supplier_id',
  field_value: 'current_user',
  operator: 'equal',
  include_nulls: false
)
puts 'Created row-level rule: Own customers only'

puts ''
puts 'Seed complete!'
puts "  Users: #{User.count}"
puts "  Groups: #{PermissionForge::PermissionSetGroup.count}"
puts "  Permission Sets: #{PermissionForge::PermissionSet.count}"
puts "  Resources: #{PermissionForge::Resource.count}"
puts "  Fields: #{PermissionForge::ResourceField.count}"
puts "  Rules: #{PermissionForge::PermissionSetRule.count}"
