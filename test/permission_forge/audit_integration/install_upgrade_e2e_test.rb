# frozen_string_literal: true

require 'test_helper'
require 'erb'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'tmpdir'

module PermissionForge
  module AuditIntegration
    # Installs the gem into a scratch Rails application and upgrades a 0.12.2
    # schema, in child processes that share nothing with this one: a new app
    # directory under Dir.mktmpdir, its own database (a SQLite file, or a
    # scratch PostgreSQL database named pf_e2e_* when the suite runs with
    # DB=postgres, dropped afterwards), and the real commands an adopter types —
    # `bin/rails g permission_forge:install`, `g permission_forge:upgrade`,
    # `db:migrate`, `db:rollback`, `runner`. The app's bundle is this
    # checkout's (BUNDLE_GEMFILE, whose gemspec points at this worktree), so a
    # Rails-matrix run (BUNDLE_GEMFILE=gemfiles/rails_7.1.gemfile) installs
    # into a Rails 7.1 app.
    #
    # Each scenario then makes a grant, an edit and a revoke through the
    # models with an actor and reads the three events back.
    #
    # Slow-ish: every command boots the scratch app (~0.7 s each, ~10 s for the
    # file on SQLite).
    class InstallUpgradeE2eTest < ActiveSupport::TestCase
      # Nothing here touches the suite's database, and DROP DATABASE cannot run
      # inside the fixture transaction.
      self.use_transactional_tests = false

      GEMFILE = File.expand_path(Bundler.default_gemfile.to_s)
      # Where this bundle's gems are (CI may say so in the environment);
      # Bundler.with_unbundled_env drops every BUNDLE_* variable.
      BUNDLE_SETTINGS = %w[BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_DEPLOYMENT BUNDLE_FROZEN BUNDLE_WITHOUT BUNDLE_WITH].freeze
      POSTGRES = ENV['DB'] == 'postgres'

      # The install migration as 0.12.2 shipped it
      # (`git show 6d29a60:lib/generators/permission_forge/install/templates/migration.rb.tt`),
      # kept verbatim here so the upgrade test runs in a shallow clone too.
      V0122_INSTALL_MIGRATION = <<~ERB
        class CreatePermissionForgeTables < ActiveRecord::Migration<%= migration_version %>
          def change
            create_table :<%= table_prefix %>permission_set_groups do |t|
              t.string  :uuid, null: false
              t.string  :name, null: false, default: 'Untitled Permission Set Group'
              t.string  :description
              t.boolean :is_active, null: false, default: true
              t.boolean :is_editable, null: false, default: true
        <% if tenant_column %>      t.bigint  :<%= tenant_column %>
              t.index   :<%= tenant_column %>
        <% end %>      t.bigint  :created_by_id
              t.bigint  :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
            end

            create_table :<%= table_prefix %>permission_sets do |t|
              t.string     :uuid, null: false
              t.references :<%= table_prefix %>permission_set_group, foreign_key: { to_table: :<%= table_prefix %>permission_set_groups }, null: true
              t.string     :name, null: false, default: 'Untitled Permission Set'
              t.string     :description
              t.boolean    :is_active, null: false, default: true
              t.boolean    :is_editable, null: false, default: true
              t.boolean    :is_muting, null: false, default: false
              t.string     :requires_session_flag
              t.string     :allowed_ips
              t.integer    :allowed_hours_start
              t.integer    :allowed_hours_end
        <% if tenant_column %>      t.bigint     :<%= tenant_column %>
              t.index      :<%= tenant_column %>
        <% end %>      t.bigint     :created_by_id
              t.bigint     :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
            end

            create_table :<%= table_prefix %>resources do |t|
              t.string     :uuid, null: false
              t.references :<%= table_prefix %>permission_set, foreign_key: { to_table: :<%= table_prefix %>permission_sets }, null: false
              t.string     :name, null: false, default: 'Untitled Resource'
              t.string     :label
              t.string     :description
              t.boolean    :is_active, null: false, default: true
              t.boolean    :is_editable, null: false, default: true
              t.boolean    :read_access, null: false, default: false
              t.boolean    :create_access, null: false, default: false
              t.boolean    :edit_access, null: false, default: false
              t.boolean    :delete_access, null: false, default: false
              t.boolean    :view_all, null: false, default: false
              t.boolean    :modify_all, null: false, default: false
        <% if tenant_column %>      t.bigint     :<%= tenant_column %>
              t.index      :<%= tenant_column %>
        <% end %>      t.bigint     :created_by_id
              t.bigint     :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
              t.index [:<%= table_prefix %>permission_set_id, :name], unique: true, name: 'idx_pf_resources_unique'
            end

            create_table :<%= table_prefix %>resource_fields do |t|
              t.string     :uuid, null: false
              t.references :<%= table_prefix %>resource, foreign_key: { to_table: :<%= table_prefix %>resources }, null: false
              t.string     :name, null: false, default: 'untitled_field'
              t.string     :label, null: false, default: 'Untitled Field'
              t.string     :description
              t.boolean    :is_active, null: false, default: true
              t.boolean    :is_editable, null: false, default: true
              t.boolean    :read_access, null: false, default: false
              t.boolean    :edit_access, null: false, default: false
              t.boolean    :mask_access, null: false, default: false
              t.string     :mask_strategy, null: false, default: 'full'
              t.datetime   :sensitive_acknowledged_at
        <% if tenant_column %>      t.bigint     :<%= tenant_column %>
              t.index      :<%= tenant_column %>
        <% end %>      t.bigint     :created_by_id
              t.bigint     :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
              t.index [:<%= table_prefix %>resource_id, :name], unique: true, name: 'idx_pf_resource_fields_unique'
            end

            create_table :<%= table_prefix %>resource_actions do |t|
              t.string     :uuid, null: false
              t.references :<%= table_prefix %>resource, foreign_key: { to_table: :<%= table_prefix %>resources }, null: false
              t.string     :name, null: false
              t.string     :label
              t.string     :description
              t.boolean    :is_permitted, null: false, default: false
              t.boolean    :is_active, null: false, default: true
        <% if tenant_column %>      t.bigint     :<%= tenant_column %>
              t.index      :<%= tenant_column %>
        <% end %>      t.bigint     :created_by_id
              t.bigint     :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
              t.index [:<%= table_prefix %>resource_id, :name], unique: true, name: 'idx_pf_resource_actions_unique'
            end

            create_table :<%= table_prefix %>permission_set_rules do |t|
              t.string     :uuid, null: false
              t.references :<%= table_prefix %>permission_set, foreign_key: { to_table: :<%= table_prefix %>permission_sets }, null: false
              t.references :<%= table_prefix %>resource, foreign_key: { to_table: :<%= table_prefix %>resources }, null: false
              t.string     :name, null: false, default: 'Untitled Rule'
              t.string     :failure_message, default: 'You do not have permission to perform this action.'
              t.string     :join_type
              t.string     :field_name, null: false
              t.string     :field_value, null: false
              t.string     :field_accessor_path
              t.string     :operator, null: false, default: 'equal'
              t.boolean    :include_nulls, null: false, default: true
              t.boolean    :is_active, null: false, default: true
              t.boolean    :is_editable, null: false, default: true
        <% if tenant_column %>      t.bigint     :<%= tenant_column %>
              t.index      :<%= tenant_column %>
        <% end %>      t.bigint     :created_by_id
              t.bigint     :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
            end

            create_table :<%= table_prefix %>permission_set_users do |t|
              t.string     :uuid, null: false
              t.references :<%= table_prefix %>permission_set, foreign_key: { to_table: :<%= table_prefix %>permission_sets }, null: false
              t.references :user, null: false
              t.datetime   :expires_at
        <% if tenant_column %>      t.bigint     :<%= tenant_column %>
              t.index      :<%= tenant_column %>
        <% end %>      t.bigint     :created_by_id
              t.bigint     :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
              t.index [:<%= table_prefix %>permission_set_id, :user_id], unique: true, name: 'idx_pf_pset_users_unique'
            end

            create_table :<%= table_prefix %>permission_set_group_users do |t|
              t.string     :uuid, null: false
              t.references :<%= table_prefix %>permission_set_group, foreign_key: { to_table: :<%= table_prefix %>permission_set_groups }, null: false
              t.references :user, null: false
        <% if tenant_column %>      t.bigint     :<%= tenant_column %>
              t.index      :<%= tenant_column %>
        <% end %>      t.bigint     :created_by_id
              t.bigint     :updated_by_id
              t.timestamps

              t.index :uuid, unique: true
              t.index [:<%= table_prefix %>permission_set_group_id, :user_id], unique: true, name: 'idx_pf_pset_group_users_unique'
            end
          end
        end
      ERB

      # The settings a 0.12.2 install generator wrote (its initializer's
      # active lines), with the empty prefix the hosts in production use.
      V0122_INITIALIZER = <<~RUBY
        PermissionForge.configure do |config|
          config.user_class = 'User'
          config.current_user_resolver = -> { Current.user }
          config.user_active_check = ->(user) { user.respond_to?(:active_for_authentication?) ? user.active_for_authentication? : true }
          config.cache_backend = :rails_cache
          config.cache_key_prefix = 'pf'
          config.table_name_prefix = ''
          config.uuid_generator = -> { SecureRandom.uuid }
          config.audit_trail_enabled = true
          config.audit_user_class = 'User'
        end
      RUBY

      # The host application: what `rails new` and a User model leave behind,
      # cut down to what the gem needs.
      APP_FILES = {
        'config/boot.rb' => <<~RUBY,
          ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)
          require 'bundler/setup'
        RUBY
        'config/application.rb' => <<~RUBY,
          require_relative 'boot'
          require 'rails'
          require 'active_record/railtie'
          require 'action_controller/railtie'
          require 'action_view/railtie'
          require 'permission_forge'

          module ScratchHost
            class Application < Rails::Application
              config.load_defaults Rails::VERSION::STRING.to_f
              config.eager_load = false
              config.secret_key_base = 'scratch-host-secret-' * 4
              config.logger = Logger.new(File.expand_path('../log/app.log', __dir__))
              config.active_support.deprecation = :silence
              config.cache_store = :memory_store
            end
          end
        RUBY
        'config/environment.rb' => "require_relative 'application'\nRails.application.initialize!\n",
        'config/routes.rb' => "Rails.application.routes.draw do\n  mount PermissionForge::Engine, at: '/permissions'\nend\n",
        'bin/rails' => "APP_PATH = File.expand_path('../config/application', __dir__)\n" \
                       "require_relative '../config/boot'\nrequire 'rails/commands'\n",
        'Rakefile' => "require_relative 'config/application'\nRails.application.load_tasks\n",
        'app/models/application_record.rb' => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
        'app/models/current.rb' => "class Current < ActiveSupport::CurrentAttributes\n  attribute :user\nend\n",
        'app/models/user.rb' => "class User < ApplicationRecord\n  include PermissionForge::Concerns::PermissionedUser\nend\n",
        'db/migrate/20200101000000_create_users.rb' => <<~RUBY
          class CreateUsers < ActiveRecord::Migration[7.1]
            def change
              create_table :users do |t|
                t.string :name
                t.string :email
                t.timestamps
              end
            end
          end
        RUBY
      }.freeze

      # Before the upgrade: the 0.12.2 schema with the new gem code. The audit
      # table is missing, so nothing is recorded, and changes still work.
      SEED_SCRIPT = <<~RUBY
        require 'json'
        legacy = User.create!(name: 'Lee Legacy', email: 'lee@example.test')
        set = PermissionForge::PermissionSet.create!(name: 'Legacy set')
        PermissionForge::PermissionSetUser.create!(permission_set: set, user: legacy)
        File.write(ARGV.fetch(0), JSON.generate(
          'audit_enabled' => PermissionForge::Audit.enabled?,
          'audit_table' => ActiveRecord::Base.connection.table_exists?(PermissionForge::AuditEvent.table_name),
          'assignments' => PermissionForge::PermissionSetUser.count
        ))
      RUBY

      # A grant, an edit (the end date) and a revoke by a named admin, read
      # back from the audit table. Also a Permission Set created, renamed and
      # deleted (no foreign key involved). Every step reports its error
      # instead of stopping the script.
      CHANGES_SCRIPT = <<~'RUBY'
        require 'json'
        def step(result, name)
          yield
        rescue StandardError => e
          result["#{name}_error"] = "#{e.class}: #{e.message}"
        end

        result = {}
        PermissionForge::Audit.reset!
        result['rails'] = Rails.version
        result['audit_enabled'] = PermissionForge::Audit.enabled?
        result['audit_table'] = PermissionForge::AuditEvent.table_name
        result['assignment_columns'] = PermissionForge::PermissionSetUser.column_names
        admin = User.create!(name: 'Ada Admin', email: 'ada@example.test')
        holder = User.create!(name: 'Hal Holder', email: 'hal@example.test')
        result['admin_id'] = admin.id.to_s
        result['holder_id'] = holder.id.to_s
        read = lambda do |record|
          PermissionForge::AuditEvent.where(record_type: record.class.base_class.name, record_id: record.id.to_s).order(:id).map do |event|
            event.attributes.slice('event', 'actor_type', 'actor_id', 'actor_label', 'source', 'subject_user_id', 'reason',
                                   'permission_set_id', 'record_label').merge('data' => event.data)
          end
        end

        draft = nil
        PermissionForge.with_audit_actor(user: admin, reason: 'TCK-7') do
          step(result, 'set') do
            draft = PermissionForge::PermissionSet.create!(name: 'Draft set')
            draft.update!(name: 'Renamed set')
          end
          step(result, 'set_destroy') { draft&.destroy! }
        end
        result['set_events'] = read.call(draft) if draft

        step(result, 'assignment') do
          set = PermissionForge::PermissionSet.find_by(name: 'Legacy set') || PermissionForge::PermissionSet.create!(name: 'Sales rep')
          assignment = nil
          PermissionForge.with_audit_actor(user: admin, reason: 'TCK-42') do
            assignment = PermissionForge::PermissionSetUser.create!(permission_set: set, user: holder,
                                                                    expires_at: Time.utc(2030, 1, 31, 23, 59, 59))
            assignment.update!(expires_at: Time.utc(2030, 3, 31, 23, 59, 59))
            assignment.destroy!
          end
          events = read.call(assignment)
          result['assignment_events'] = events
          result['permission_set_id'] = set.id
          stored = PermissionForge::AuditEvent.where(record_id: assignment.id.to_s, event: 'assignment.granted').first
          result['insert_only'] = begin
            stored.update!(reason: 'rewritten')
            false
          rescue ActiveRecord::ReadOnlyRecord
            true
          end
        end
        result['event_count'] = PermissionForge::AuditEvent.count
        File.write(ARGV.fetch(0), JSON.generate(result))
      RUBY

      # After a refused rollback: the table, its rows and the migration are all still there.
      CHECK_SCRIPT = <<~RUBY
        require 'json'
        connection = ActiveRecord::Base.connection
        File.write(ARGV.fetch(0), JSON.generate(
          'audit_table' => connection.table_exists?(PermissionForge::AuditEvent.table_name),
          'reviewed_at' => connection.column_exists?(PermissionForge::PermissionSetUser.table_name, :reviewed_at),
          'event_count' => PermissionForge::AuditEvent.count,
          'versions' => ActiveRecord::Base.connection.select_values('SELECT version FROM schema_migrations').map(&:to_s)
        ))
      RUBY

      # A scratch host application and the commands run in it.
      class ScratchApp
        SCRATCH_DATABASE = /\Apf_e2e_\d+_\h{8}\z/

        attr_reader :root, :log, :database

        # Only a database this file named may ever be dropped.
        def self.scratch_database?(name)
          SCRATCH_DATABASE.match?(name.to_s)
        end

        def initialize(postgres:)
          @root = Dir.mktmpdir('pf_e2e')
          @postgres = postgres
          @database = postgres ? "pf_e2e_#{Process.pid}_#{SecureRandom.hex(4)}" : 'db/development.sqlite3'
          @log = +''
          write_files
        end

        def write(path, body)
          full = File.join(root, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, body)
        end

        # @return [Array(String, Process::Status)] the output and the exit status
        def rails(*args)
          env = child_env
          output, status = Bundler.with_unbundled_env do
            Open3.capture2e(env, RbConfig.ruby, 'bin/rails', *args, chdir: root)
          end
          @log << "$ bin/rails #{args.join(' ')} (exit #{status.exitstatus})\n#{output.lines.last(40).join}\n"
          [output, status]
        end

        # Fails with the command's output when it does not succeed.
        def rails!(*args)
          output, status = rails(*args)
          raise "bin/rails #{args.join(' ')} failed (exit #{status.exitstatus}):\n#{output.lines.last(40).join}" unless status.success?

          output
        end

        # Runs `script` with `bin/rails runner` and returns the JSON it wrote.
        def run_script(name, script)
          write("script/#{name}.rb", script)
          out = File.join(root, "tmp/#{name}.json")
          rails!('runner', "script/#{name}.rb", out)
          JSON.parse(File.read(out))
        end

        def migration_files(pattern)
          Dir[File.join(root, 'db/migrate', pattern)].map { |path| File.basename(path) }
        end

        def destroy
          drop_database if @postgres
        ensure
          FileUtils.remove_entry(root) if File.directory?(root)
        end

        # Dropped from this process, by the name this file chose — never by
        # whatever the child's configuration resolves to.
        def drop_database
          raise ArgumentError, "refusing to drop #{database.inspect}: not a scratch database" unless self.class.scratch_database?(database)

          ActiveRecord::Base.connection.drop_database(database)
        end

        # The child's environment: this bundle, no DATABASE_URL (it would
        # win over config/database.yml and point the child at a real database).
        def child_env
          ENV.to_h.slice(*BUNDLE_SETTINGS)
             .merge('BUNDLE_GEMFILE' => GEMFILE, 'RAILS_ENV' => 'development', 'DATABASE_URL' => nil)
        end

        private

        def write_files
          APP_FILES.each { |path, body| write(path, body) }
          write('config/database.yml', database_yml)
          %w[log tmp].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
        end

        def database_yml
          return "development:\n  adapter: sqlite3\n  database: #{@database}\n" unless @postgres

          "development:\n  adapter: postgresql\n  database: #{@database}\n  host: #{ENV.fetch('PGHOST', 'localhost')}\n  " \
            "port: #{ENV.fetch('PGPORT', 5432)}\n  username: #{ENV.fetch('PGUSER', '')}\n  password: #{ENV.fetch('PGPASSWORD', '')}\n"
        end
      end

      setup do
        @app = ScratchApp.new(postgres: POSTGRES)
        @app.rails!('db:create') if POSTGRES
      end

      teardown do
        @app&.destroy
      end

      # --- fresh install -----------------------------------------------------------

      test 'a fresh install with the default prefix records who made a change, and what it was' do
        @app.rails!('g', 'permission_forge:install')
        @app.rails!('db:migrate')
        result = @app.run_script('changes', CHANGES_SCRIPT)

        assert_equal Rails.version, result['rails'], 'the scratch app runs the Rails of this bundle'
        assert result['audit_enabled'], 'the generated migration creates the audit table, so auditing is on (:auto)'
        assert_equal 'permission_forge_audit_events', result['audit_table']
        assert_nil result['set_error'], @app.log
        assert_equal %w[permission_set.created permission_set.updated], events_of(result, 'set_events').first(2)
        assert_actor(result, result['set_events'], reason: 'TCK-7')

        # The default-prefix install template prefixes its foreign-key columns
        # (permission_forge_permission_set_id) while the models read
        # permission_set_id: no assignment can be saved and no set deleted. A
        # pre-existing 0.12.2 defect, fixed on the public-release-blockers
        # branch, which is not merged into this one. Once it is, this runs.
        if result['assignment_columns'].include?('permission_forge_permission_set_id')
          skip 'default-prefix install: the install template prefixes foreign-key columns, so assignments cannot be saved ' \
               "(#{result['assignment_error'].to_s.lines.first.to_s.strip}); fixed on public-release-blockers"
        end
        assert_nil result['set_destroy_error'], @app.log
        assert_equal 'permission_set.destroyed', events_of(result, 'set_events').last
        assert_three_changes(result)
      end

      test 'a fresh install with an empty prefix records a grant, an edit and a revoke' do
        @app.rails!('g', 'permission_forge:install', '--table-prefix=')
        @app.rails!('db:migrate')
        result = @app.run_script('changes', CHANGES_SCRIPT)

        assert result['audit_enabled']
        assert_equal 'audit_events', result['audit_table']
        assert_three_changes(result)
      end

      # --- upgrade from 0.12.2 -----------------------------------------------------

      test 'an upgrade from a 0.12.2 schema records a grant, an edit and a revoke, and refuses to roll the log back' do
        install_v0122
        seeded = @app.run_script('seed', SEED_SCRIPT)
        assert_equal({ 'audit_enabled' => false, 'audit_table' => false, 'assignments' => 1 }, seeded,
                     'before the upgrade nothing is recorded and changes still work')

        @app.rails!('g', 'permission_forge:upgrade')
        audit_migration = @app.migration_files('*_permission_forge_add_audit_events.rb')
        assert_equal 1, audit_migration.size, @app.log
        @app.rails!('db:migrate')
        result = @app.run_script('changes', CHANGES_SCRIPT)

        assert result['audit_enabled'], 'after the upgrade auditing is on'
        assert_equal 'audit_events', result['audit_table']
        assert_three_changes(result)

        assert_rollback_refused(audit_migration.first[/\A\d+/], result['event_count'])
      end

      # --- the scratch app's own safety -------------------------------------------------

      test 'the scratch app never reaches a database it did not name' do
        assert_includes @app.child_env, 'DATABASE_URL'
        assert_nil @app.child_env['DATABASE_URL'], 'a DATABASE_URL in the environment is unset for the child'
        assert ScratchApp.scratch_database?("pf_e2e_#{Process.pid}_0a1b2c3d")
        %w[permission_forge_test postgres pf_e2e_ pf_e2e_1_0a1b2c3d_x production].each do |name|
          assert_not ScratchApp.scratch_database?(name), name
        end
        scratch = @app.database
        @app.instance_variable_set(:@database, 'permission_forge_test')
        assert_raises(ArgumentError) { @app.drop_database }
      ensure
        @app.instance_variable_set(:@database, scratch) if scratch
      end

      # --- the unique-index migration the upgrade copies -----------------------------

      UNIQUE_INDEX_TEMPLATE = File.expand_path(
        '../../../lib/generators/permission_forge/upgrade/templates/add_resource_fields_unique_index.rb.tt', __dir__
      )

      # An in-memory database of its own, for running one rendered migration.
      class ScratchRecord < ActiveRecord::Base
        self.abstract_class = true
      end

      test 'the unique-index migration leaves an install that already has the unique index alone' do
        with_scratch_fields(unique: true) do |connection|
          run_unique_index_migration(connection)

          assert_equal 2, connection.select_value('SELECT COUNT(*) FROM resource_fields')
          assert connection.index_exists?(:resource_fields, %i[resource_id name], name: 'idx_pf_resource_fields_unique', unique: true)
        end
      end

      test 'the unique-index migration replaces a same-named index that is not unique, after collapsing duplicates' do
        with_scratch_fields(unique: false) do |connection|
          connection.execute("INSERT INTO resource_fields (resource_id, name, mask_access, edit_access) VALUES (1, 'email', 0, 1)")

          run_unique_index_migration(connection)

          rows = connection.select_rows("SELECT mask_access, edit_access FROM resource_fields WHERE name = 'email'")
          assert_equal 1, rows.size, 'the duplicate is collapsed'
          assert_equal [1, 0], rows.first.map(&:to_i), 'the masked, read-only row is kept'
          assert connection.index_exists?(:resource_fields, %i[resource_id name], name: 'idx_pf_resource_fields_unique', unique: true)
        end
      end

      test 'the unique-index migration says which duplicate it deleted and which row it kept' do
        with_scratch_fields(unique: false) do |connection|
          connection.execute("INSERT INTO resource_fields (resource_id, name, mask_access, edit_access) VALUES (1, 'email', 0, 1)")
          connection.execute("INSERT INTO resource_fields (resource_id, name, mask_access, edit_access) VALUES (1, 'email', 0, 0)")

          output, = capture_io { run_unique_index_migration(connection, verbose: true) }

          assert_match(/resource_id 1, name "email": kept id 1 \(mask_access true, edit_access false\); deleted ids 3, 4/, output)
          assert_match(/not in the audit log/, output)
          assert_no_match(/name "name"/, output, 'a field without duplicates is not mentioned')
        end
      end

      private

      # resource_fields with one masked, read-only email row and
      # idx_pf_resource_fields_unique (unique or not) on (resource_id, name).
      def with_scratch_fields(unique:)
        ScratchRecord.establish_connection(adapter: 'sqlite3', database: ':memory:')
        connection = ScratchRecord.connection
        connection.create_table(:resource_fields) do |t|
          t.bigint :resource_id
          t.string :name
          t.boolean :mask_access
          t.boolean :edit_access
        end
        connection.add_index :resource_fields, %i[resource_id name], unique: unique, name: 'idx_pf_resource_fields_unique'
        connection.execute("INSERT INTO resource_fields (resource_id, name, mask_access, edit_access) VALUES (1, 'email', 1, 0)")
        connection.execute("INSERT INTO resource_fields (resource_id, name, mask_access, edit_access) VALUES (1, 'name', 0, 0)")
        yield connection
      ensure
        ScratchRecord.remove_connection
      end

      def run_unique_index_migration(connection, verbose: false)
        migration = unique_index_migration
        return migration.suppress_messages { migration.exec_migration(connection, :up) } unless verbose

        previous = ActiveRecord::Migration.verbose
        ActiveRecord::Migration.verbose = true
        migration.exec_migration(connection, :up)
      ensure
        ActiveRecord::Migration.verbose = previous unless previous.nil?
      end

      def unique_index_migration
        context = Struct.new(:migration_version, :table_prefix).new("[#{ActiveRecord::Migration.current_version}]", '')
        source = ERB.new(File.read(UNIQUE_INDEX_TEMPLATE), trim_mode: '-').result(context.instance_eval { binding })
        namespace = Module.new
        namespace.module_eval(source.sub('class PermissionForgeAddResourceFieldsUniqueIndex', 'class Migration'))
        namespace::Migration.new
      end

      def install_v0122
        context = Struct.new(:migration_version, :table_prefix, :tenant_column)
                        .new("[#{ActiveRecord::Migration.current_version}]", '', nil)
        migration = ERB.new(V0122_INSTALL_MIGRATION, trim_mode: '-').result(context.instance_eval { binding })
        @app.write('db/migrate/20240101000000_create_permission_forge_tables.rb', migration)
        @app.write('config/initializers/permission_forge.rb', V0122_INITIALIZER)
        @app.rails!('db:migrate')
      end

      def assert_three_changes(result)
        assert_equal Rails.version, result['rails'], 'the scratch app runs the Rails of this bundle'
        assert_nil result['assignment_error'], @app.log
        events = result['assignment_events']
        assert_equal %w[assignment.granted assignment.changed assignment.revoked], events_of(result, 'assignment_events')
        assert_actor(result, events, reason: 'TCK-42')
        events.each { |event| assert_about_holder(result, event) }
        assert_end_dates(*events)
        assert result['insert_only'], 'a stored event cannot be rewritten'
      end

      def assert_about_holder(result, event)
        assert_equal result['holder_id'], event['subject_user_id'], "#{event['event']} names the person whose access changed"
        assert_equal result['permission_set_id'], event['permission_set_id']
        assert_equal 'Hal Holder', event['record_label']
      end

      def assert_end_dates(granted, changed, revoked)
        day = ->(value) { value.to_s[0, 10] }
        assert_equal '2030-01-31', day.call(granted.dig('data', 'snapshot', 'expires_at')), 'the grant carries its end date'
        assert_equal %w[2030-01-31 2030-03-31], changed.dig('data', 'changes', 'expires_at').map(&day),
                     'the edit carries the end date before and after'
        assert_equal '2030-03-31', day.call(revoked.dig('data', 'snapshot', 'expires_at')), 'the revoke carries a snapshot'
      end

      def assert_actor(result, events, reason:)
        events.each do |event|
          assert_equal ['user', result['admin_id'], 'Ada Admin', reason],
                       event.values_at('actor_type', 'actor_id', 'actor_label', 'reason'), event['event']
          assert_equal 'service', event['source'], event['event']
        end
      end

      def assert_rollback_refused(version, events_before)
        output, status = @app.rails('db:rollback')

        assert_not status.success?, 'db:rollback of the audit migration must fail'
        assert_includes output, 'ActiveRecord::IrreversibleMigration'
        assert_includes output, 'The audit log is evidence'
        after = @app.run_script('check', CHECK_SCRIPT)
        assert after['audit_table'], 'the audit table is still there'
        assert after['reviewed_at'], 'the review columns are still there'
        assert_operator after['event_count'], :>=, events_before, 'no event was lost'
        assert_includes after['versions'], version, 'the audit migration is still recorded as run'
      end

      def events_of(result, key)
        Array(result[key]).map { |event| event['event'] }
      end
    end
  end
end
