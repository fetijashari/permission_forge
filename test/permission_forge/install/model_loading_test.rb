# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'json'

module PermissionForge
  module Install
    # The models are autoloaded by the host application (app/models), so what
    # a class body reads from the configuration — the user class of an
    # assignment, the audit user class, the tenant model, the table prefix —
    # is what the host's config/initializers set, with nothing re-declared
    # after boot; and what a class body does NOT read from the host (its
    # `belongs_to_required_by_default`) stays the gem's own. Each test boots
    # test/dummy in a child process in the development environment
    # (reloading on) under `ruby -w`, against an in-memory database, and
    # reads the JSON the child prints.
    class ModelLoadingTest < ActiveSupport::TestCase
      APPLICATION = File.expand_path('../../dummy/config/application', __dir__)
      SCHEMA = File.expand_path('../../dummy/db/schema', __dir__)
      CHILD_ENV = { 'DATABASE_URL' => 'sqlite3::memory:', 'RAILS_ENV' => 'development', 'DB' => nil, 'RUBYOPT' => '-w' }.freeze
      # The accessors a belongs_to defines, for the models' configurable associations.
      ASSOCIATION_METHODS = /\b(?:build_|create_|reload_|reset_)?(?:user|created_by|updated_by)(?:=|!|_changed\?|_previously_changed\?)?\b/

      # What a host puts in config/initializers/permission_forge.rb, after the
      # dummy's own initializer (which sets user_class = 'User').
      HOST_CONFIG = <<~RUBY
        class PfLoadMember < ActiveRecord::Base
          self.table_name = 'users'
        end

        class PfLoadAuditor < ActiveRecord::Base
          self.table_name = 'users'
        end

        Rails.application.initializer('pf_load_host_config', after: :load_config_initializers) do
          PermissionForge.configure do |config|
            config.user_class = 'PfLoadMember'
            config.audit_user_class = 'PfLoadAuditor'
            config.tenant_model = 'Account'
            config.table_name_prefix = 'pfx_'
          end
        end
      RUBY

      # The models as a host sees them: what each association points at,
      # whether the tenant scope is on, the table name, the identity of the
      # class (a reload gives a new one), and whether a change a host made to
      # the class is still there.
      FACTS = <<~RUBY
        def pf_facts
          models = PermissionForge::MODEL_NAMES.map { |name| PermissionForge.const_get(name) }
          {
            'user_class' => PermissionForge::PermissionSetUser.reflect_on_association(:user).class_name,
            'group_user_class' => PermissionForge::PermissionSetGroupUser.reflect_on_association(:user).class_name,
            'created_by_classes' => models.filter_map { |m| m.reflect_on_association(:created_by)&.class_name }.uniq,
            'tenant_scoped' => models.count(&:tenant_scoping_applied?),
            'default_scopes' => models.map { |m| m.default_scopes.size }.uniq,
            'table_names' => models.map(&:table_name),
            'object_ids' => models.map(&:object_id),
            'loaded' => PermissionForge::MODEL_NAMES.count { |name| PermissionForge.autoload?(name).nil? },
            'on_load_change' => PermissionForge::PermissionSet.method_defined?(:pf_on_load_label),
            'after_initialize_change' => PermissionForge::PermissionSet.method_defined?(:pf_after_initialize_label)
          }
        end
      RUBY

      test 'a model reads the configuration as it loads, and again after a code reload' do
        result = boot(<<~RUBY)
          #{HOST_CONFIG}
          #{FACTS}
          Rails.application.config.after_initialize { $pf_after_initialize = PermissionForge::PermissionSet.name }
          Rails.application.config.to_prepare { $pf_to_prepare = (($pf_to_prepare || 0) + 1) if PermissionForge::PermissionSetUser }
          # The two ways a host may change a model class — and the one it may not.
          Rails.autoloaders.main.on_load('PermissionForge::PermissionSet') { |klass, _| klass.class_eval { def pf_on_load_label = 'host' } }
          Rails.application.config.after_initialize { PermissionForge::PermissionSet.class_eval { def pf_after_initialize_label = 'host' } }
          Rails.application.initialize!
          out = { 'after_initialize' => $pf_after_initialize, 'to_prepare_runs' => $pf_to_prepare, 'booted' => pf_facts }
          Rails.application.eager_load!
          out['eager'] = pf_facts
          Rails.application.reloader.reload!
          out['reloaded'] = pf_facts
          out['to_prepare_runs_after_reload'] = $pf_to_prepare
          out['permission_models_are_current'] = PermissionForge::ModelBindings.loaded_models.first.equal?(PermissionForge::PermissionSet)
          puts JSON.generate(out)
        RUBY

        assert_equal 'PermissionForge::PermissionSet', result['after_initialize'], 'after_initialize may reference a model'
        assert_equal 1, result['to_prepare_runs'], 'to_prepare may reference a model'
        # A reload runs the prepare callbacks again (Rails runs them after the
        # reloader's run and once more from reload!), on the reloaded class.
        assert_operator result['to_prepare_runs_after_reload'], :>, 1, 'to_prepare ran again after the reload'
        assert_equal 9, result['eager']['loaded'], 'eager loading loads every model'
        %w[booted eager reloaded].each { |stage| assert_configured(result[stage], stage) }
        assert_equal 9, result['reloaded']['loaded'], 'the models were loaded again after the reload'
        assert_empty result['booted']['object_ids'] & result['reloaded']['object_ids'], 'a reload gives new classes'
        assert result['permission_models_are_current'], 'the engine resolves the reloaded classes'
        assert_empty result['redefined'], "the gem redefined association methods:\n#{result['redefined'].join("\n")}"
        assert_host_changes(result)
      end

      test 'a model referenced from the top level of an initializer says where it may be referenced' do
        result = boot(<<~RUBY, expect_success: false)
          Rails.application.initializer('pf_load_bad_host_initializer', after: :load_config_initializers) do
            PermissionForge::PermissionSet
          end
          Rails.application.initialize!
        RUBY

        assert_match(/NameError/, result['output'])
        assert_match(/PermissionForge::PermissionSet is autoloaded by the Rails application once it has booted/, result['output'])
        assert_match(/Rails\.application\.config\.to_prepare/, result['output'])
        assert_match(/Rails\.autoloaders\.main\.on_load\('PermissionForge::PermissionSet'\)/, result['output'])
        assert_match(/after_initialize runs once/, result['output'])
      end

      # Which belongs_to carry Rails' "must exist" validation: the 0.13 shape
      # (parents optional — the foreign key holds — the user and the tenant
      # required, created_by/updated_by optional, the audit event's tenant
      # optional), whatever the host's belongs_to_required_by_default: a
      # permission row's tenant must not depend on a host-wide default.
      REQUIRED = {
        'PermissionSet' => %w[account], 'PermissionSetUser' => %w[account user], 'PermissionSetGroup' => %w[account],
        'PermissionSetGroupUser' => %w[account user], 'Resource' => %w[account], 'ResourceField' => %w[account],
        'ResourceAction' => %w[account], 'PermissionSetRule' => %w[account], 'AuditEvent' => []
      }.freeze
      OPTIONAL = {
        'PermissionSet' => %w[created_by permission_set_group updated_by],
        'PermissionSetUser' => %w[created_by permission_set updated_by],
        'PermissionSetGroup' => %w[created_by updated_by],
        'PermissionSetGroupUser' => %w[created_by permission_set_group updated_by],
        'Resource' => %w[created_by permission_set updated_by],
        'ResourceField' => %w[created_by resource updated_by], 'ResourceAction' => %w[created_by resource updated_by],
        'PermissionSetRule' => %w[created_by permission_set resource updated_by], 'AuditEvent' => %w[account]
      }.freeze

      test 'the models\' belongs_to validations do not follow the host\'s belongs_to_required_by_default' do
        with_default, without_default = [true, false].map { |setting| boot(validations_script(setting)) }

        assert_equal [true, false], [with_default['brbd'], without_default['brbd']], 'the host setting itself applies'
        [with_default, without_default].each do |result|
          assert_equal REQUIRED, result['required'], "belongs_to_required_by_default = #{result['brbd']}"
          assert_equal OPTIONAL, result['optional'], "belongs_to_required_by_default = #{result['brbd']}"
          assert_includes result['tenantless_set_errors'], 'must exist', 'a set without a tenant is refused'
          assert_includes result['assignment_user_errors'], 'must exist', 'an assignment needs its user'
          assert_empty result['assignment_set_errors'], 'the parent stays optional, as in 0.13 (the foreign key holds)'
          assert_empty result['orphan_resource_errors'], 'the parent stays optional, as in 0.13 (the foreign key holds)'
        end
      end

      # Configuring after config/initializers changes nothing in a class that
      # already loaded — in production every class, eager-loaded before the
      # host's after_initialize blocks run. The engine says so in the log.
      test 'a setting the host changes in after_initialize, after the eager load, is logged' do
        result = boot(<<~RUBY)
          # As in production (config/environments/development.rb, loaded by initialize!, says false).
          Rails.application.initializer('pf_eager_load', after: :load_environment_config) { Rails.application.config.eager_load = true }
          Rails.application.config.logger = ActiveSupport::Logger.new($stdout)
          Rails.application.config.after_initialize { PermissionForge.configuration.user_class = 'PfLateMember' }
          Rails.application.initialize!
          puts JSON.generate('declared' => PermissionForge::PermissionSetUser.reflect_on_association(:user).class_name)
        RUBY

        assert_equal 'User', result['declared'], 'the eager-loaded class keeps what it declared'
        assert_includes result['output'], '[PermissionForge] config.user_class is "PfLateMember" but ' \
                                          'PermissionForge::PermissionSetUser, PermissionForge::PermissionSetGroupUser ' \
                                          'loaded with "User"'
        assert_match(%r{Configure PermissionForge in config/initializers}, result['output'])
      end

      private

      def validations_script(belongs_to_required_by_default)
        <<~RUBY
          Rails.application.initializer('pf_load_host_config', after: :load_config_initializers) do
            Rails.application.config.active_record.belongs_to_required_by_default = #{belongs_to_required_by_default}
            PermissionForge.configure { |config| config.tenant_model = 'Account' }
          end
          Rails.application.initialize!
          ActiveRecord::Schema.verbose = false
          load #{"#{SCHEMA}.rb".dump}
          models = PermissionForge::MODEL_NAMES.to_h { |name| [name.to_s, PermissionForge.const_get(name)] }
          required = models.transform_values do |model|
            model.reflect_on_all_associations(:belongs_to).select do |reflection|
              !reflection.options[:optional] &&
                model.validators_on(reflection.name).any? { |v| v.kind == :presence && v.options[:message] == :required }
            end.map { |reflection| reflection.name.to_s }.sort
          end
          optional = models.to_h do |name, model|
            [name, (model.reflect_on_all_associations(:belongs_to).map { |r| r.name.to_s } - required[name]).sort]
          end
          ActsAsTenant.current_tenant = nil
          set = PermissionForge::PermissionSet.new(name: 'Tenantless').tap(&:validate)
          resource = PermissionForge::Resource.new(name: 'Customer', read_access: true).tap(&:validate)
          assignment = PermissionForge::PermissionSetUser.new.tap(&:validate)
          puts JSON.generate(
            'brbd' => ActiveRecord::Base.belongs_to_required_by_default, 'required' => required, 'optional' => optional,
            'tenantless_set_errors' => set.errors[:account], 'orphan_resource_errors' => resource.errors[:permission_set],
            'assignment_user_errors' => assignment.errors[:user], 'assignment_set_errors' => assignment.errors[:permission_set]
          )
        RUBY
      end

      def assert_configured(facts, stage)
        assert_equal 'PfLoadMember', facts['user_class'], "#{stage}: PermissionSetUser#user"
        assert_equal 'PfLoadMember', facts['group_user_class'], "#{stage}: PermissionSetGroupUser#user"
        assert_equal ['PfLoadAuditor'], facts['created_by_classes'], "#{stage}: created_by"
        assert_equal 9, facts['tenant_scoped'], "#{stage}: every model is tenant scoped"
        assert_equal [1], facts['default_scopes'], "#{stage}: once"
        assert facts['table_names'].all? { |name| name.start_with?('pfx_') }, "#{stage}: #{facts['table_names']}"
      end

      # A change made from Rails.autoloaders.main.on_load survives a reload
      # (and is there after an eager load); one made from after_initialize is
      # gone after the first reload — which is why the gem's NameError says
      # to use after_initialize only to read.
      def assert_host_changes(result)
        %w[booted eager].each do |stage|
          assert result[stage]['on_load_change'], "#{stage}: on_load change"
          assert result[stage]['after_initialize_change'], "#{stage}: after_initialize change"
        end
        assert result['reloaded']['on_load_change'], 'an on_load change is made again on the reloaded class'
        assert_not result['reloaded']['after_initialize_change'], 'an after_initialize change is lost at the first reload'
      end

      # Boots the dummy app with `script` after config/application has loaded.
      # Returns the JSON the script printed plus the redefinition warnings of
      # the models' association methods ('redefined') and the whole output.
      def boot(script, expect_success: true)
        output, status = Open3.capture2e(CHILD_ENV, RbConfig.ruby, '-e', "require #{APPLICATION.dump}\n#{script}")
        assert_equal expect_success, status.success?, "exit #{status.exitstatus}:\n#{output.lines.last(30).join}"
        json = output.lines.reverse.find { |line| line.start_with?('{') }
        (json ? JSON.parse(json) : {}).merge('output' => output, 'redefined' => association_redefinitions(output))
      end

      def association_redefinitions(output)
        output.lines.grep(/warning: method redefined; discarding old (\S+)/).select { |line| line[ASSOCIATION_METHODS] }
      end
    end
  end
end
