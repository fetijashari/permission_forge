ActiveRecord::Schema.define do
  create_table :accounts, force: true do |t|
    t.string :name, null: false
    t.timestamps
  end

  create_table :users, force: true do |t|
    t.string  :uuid
    t.string  :name
    t.string  :email
    t.boolean :deactivated, default: false
    t.bigint  :account_id
    t.timestamps
  end

  create_table :suppliers, force: true do |t|
    t.string  :uuid
    t.string  :name
    t.bigint  :owner_id
    t.bigint  :account_id
    t.timestamps
  end

  create_table :customers, force: true do |t|
    t.string  :uuid
    t.string  :name
    t.string  :email
    t.string  :domain
    t.bigint  :supplier_id
    t.bigint  :account_id
    t.timestamps
  end

  # Host shapes the models above do not have (host_shapes_test.rb): a
  # namespaced model on a uuid primary key (Billing::Invoice), and one with
  # an encrypted column and an enum (PfEncryptedNote).
  create_table :billing_invoices, id: :string, primary_key: :uuid, force: true do |t|
    t.string  :number
    t.integer :amount_cents
    t.string  :customer_email
    t.bigint  :owner_id
    t.bigint  :account_id
    t.timestamps
  end

  create_table :pf_encrypted_notes, force: true do |t|
    t.string  :title
    t.text    :body
    t.integer :status, null: false, default: 0
    t.bigint  :owner_id
    t.bigint  :account_id
    t.timestamps
  end

  # PermissionForge tables (no prefix for test simplicity)
  create_table :permission_set_groups, force: true do |t|
    t.string  :uuid, null: false
    t.string  :name, null: false
    t.string  :description
    t.boolean :is_active, null: false, default: true
    t.boolean :is_editable, null: false, default: true
    t.bigint  :account_id
    t.bigint  :created_by_id
    t.bigint  :updated_by_id
    t.timestamps
  end

  create_table :permission_sets, force: true do |t|
    t.string  :uuid, null: false
    t.bigint  :permission_set_group_id
    t.string  :name, null: false
    t.string  :description
    t.boolean :is_active, null: false, default: true
    t.boolean :is_editable, null: false, default: true
    t.boolean :is_muting, null: false, default: false
    t.string  :requires_session_flag
    t.string  :allowed_ips
    t.integer :allowed_hours_start
    t.integer :allowed_hours_end
    t.bigint  :account_id
    t.bigint  :created_by_id
    t.bigint  :updated_by_id
    t.timestamps
  end

  create_table :resources, force: true do |t|
    t.string  :uuid, null: false
    t.bigint  :permission_set_id, null: false
    t.string  :name, null: false, default: 'Untitled Resource'
    t.string  :label
    t.string  :description
    t.boolean :is_active, null: false, default: true
    t.boolean :is_editable, null: false, default: true
    t.boolean :read_access, null: false, default: false
    t.boolean :create_access, null: false, default: false
    t.boolean :edit_access, null: false, default: false
    t.boolean :delete_access, null: false, default: false
    t.boolean :view_all, null: false, default: false
    t.boolean :modify_all, null: false, default: false
    t.bigint  :account_id
    t.bigint  :created_by_id
    t.bigint  :updated_by_id
    t.timestamps
    t.index %i[permission_set_id name], unique: true
  end

  create_table :resource_fields, force: true do |t|
    t.string  :uuid, null: false
    t.bigint  :resource_id, null: false
    t.string  :name, null: false, default: 'untitled_field'
    t.string  :label, null: false, default: 'Untitled Field'
    t.string  :description
    t.boolean :is_active, null: false, default: true
    t.boolean :is_editable, null: false, default: true
    t.boolean :read_access, null: false, default: false
    t.boolean :edit_access, null: false, default: false
    t.boolean :mask_access, null: false, default: false
    t.string  :mask_strategy, null: false, default: 'full'
    t.datetime :sensitive_acknowledged_at
    t.bigint  :sensitive_acknowledged_by_id
    t.bigint  :account_id
    t.bigint  :created_by_id
    t.bigint  :updated_by_id
    t.timestamps

    t.index [:resource_id, :name], unique: true, name: 'idx_pf_resource_fields_unique'
  end

  create_table :resource_actions, force: true do |t|
    t.string  :uuid, null: false
    t.bigint  :resource_id, null: false
    t.string  :name, null: false
    t.string  :label
    t.string  :description
    t.boolean :is_permitted, null: false, default: false
    t.boolean :is_active, null: false, default: true
    t.bigint  :account_id
    t.bigint  :created_by_id
    t.bigint  :updated_by_id
    t.timestamps
  end

  create_table :permission_set_rules, force: true do |t|
    t.string  :uuid, null: false
    t.bigint  :permission_set_id, null: false
    t.bigint  :resource_id, null: false
    t.string  :name, null: false
    t.string  :failure_message
    t.string  :join_type
    t.string  :field_name, null: false
    t.string  :field_value, null: false
    t.string  :field_accessor_path
    t.string  :operator, null: false, default: 'equal'
    t.boolean :include_nulls, null: false, default: true
    t.boolean :is_active, null: false, default: true
    t.boolean :is_editable, null: false, default: true
    t.bigint  :account_id
    t.bigint  :created_by_id
    t.bigint  :updated_by_id
    t.timestamps
  end

  create_table :permission_set_users, force: true do |t|
    t.string   :uuid, null: false
    t.bigint   :permission_set_id, null: false
    t.bigint   :user_id, null: false
    t.datetime :expires_at
    t.datetime :reviewed_at
    t.bigint   :reviewed_by_id
    t.string   :reason
    t.bigint   :account_id
    t.bigint   :created_by_id
    t.bigint   :updated_by_id
    t.timestamps

    t.index [:permission_set_id, :user_id], unique: true, name: 'idx_pf_permission_set_users_unique'
  end

  create_table :permission_set_group_users, force: true do |t|
    t.string  :uuid, null: false
    t.bigint  :permission_set_group_id, null: false
    t.bigint  :user_id, null: false
    t.string  :reason
    t.bigint  :account_id
    t.bigint  :created_by_id
    t.bigint  :updated_by_id
    t.timestamps

    t.index [:permission_set_group_id, :user_id], unique: true, name: 'idx_pf_psg_users_unique'
  end

  # Audit event log (docs/audit-log.md). No
  # updated_at and no foreign keys: events outlive the records they are about.
  create_table :audit_events, force: true do |t|
    t.string   :uuid, null: false
    t.datetime :occurred_at, null: false, precision: 6
    t.string   :event, null: false
    t.string   :category, null: false
    t.string   :actor_type, null: false
    t.string   :actor_id
    t.string   :actor_label
    t.string   :source, null: false
    t.string   :record_type
    t.string   :record_id
    t.string   :record_uuid
    t.string   :record_label
    t.bigint   :permission_set_id
    t.string   :permission_set_uuid
    t.string   :subject_user_id
    t.text     :data
    t.string   :reason
    t.string   :request_id
    t.string   :ip
    t.string   :correlation_id
    t.bigint   :account_id
    t.datetime :created_at, null: false

    # Index names as the install/upgrade generators write them.
    t.index :account_id, name: 'idx_pf_audit_tenant'
    t.index :uuid, unique: true, name: 'idx_pf_audit_uuid'
    t.index :occurred_at, name: 'idx_pf_audit_occurred'
    t.index %i[event occurred_at], name: 'idx_pf_audit_event'
    t.index %i[subject_user_id occurred_at], name: 'idx_pf_audit_subject'
    t.index %i[permission_set_id occurred_at], name: 'idx_pf_audit_pset'
    t.index %i[permission_set_uuid occurred_at], name: 'idx_pf_audit_pset_uuid'
    t.index %i[record_type record_id occurred_at], name: 'idx_pf_audit_record'
    t.index %i[actor_id occurred_at], name: 'idx_pf_audit_actor'
    t.index :correlation_id, name: 'idx_pf_audit_correlation'
  end
end
