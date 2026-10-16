# frozen_string_literal: true

require 'test_helper'
require_relative '../security/shipped_api_authorization'

module PermissionForge
  module ReleaseReadiness
    # The pre-release review of 2026-10-12, claims lane: what the docs, the gemspec and the generated
    # initializer promise, checked against what the code does. A claim that
    # was made true in code gets a behaviour test; a claim that stays false
    # by design gets its true behaviour pinned and is named as a limit; the
    # wording Phase 2 rewrote (the generated initializer, README, gemspec,
    # docs) is checked as text. Where a finding was a defect the test failed
    # on v0.13.0.
    class ClaimsRegressionTest < ActionDispatch::IntegrationTest
      include PermissionForge::Security::ShippedApiAuthorization

      ROOT = '/permission_forge'
      GEM_ROOT = File.expand_path('../../..', __dir__)

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
        PermissionForge.configuration.auto_query_scoping = :off
      end

      def read(path) = File.read(File.join(GEM_ROOT, path))

      def readable_customer_set(**attrs)
        set = create_permission_set(name: 'Readers', **attrs)
        create_resource(permission_set: set, name: 'Customer', read_access: true)
        set
      end

      # ---- #1 FALSE: "a forged cross-site POST gets an empty session" ---------------

      # docs/admin-api.md promised that a session-based api_auth defeats a
      # forged form post. In 0.13 api_auth ran before the null session and saw
      # the real one: the forged mutation went through. With forgery
      # protection on, as in production.
      test 'CLAIMS-1 a forged cross-site POST reaches a session-based api_auth with an empty session' do
        PermissionForge.configuration.api_auth = ->(controller) { controller.session[:permission_forge_locale] == 'sq' }
        get "#{ROOT}/permission_sets", params: { locale: 'sq' } # the victim's admin session
        assert_response :ok

        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'forged' } }
        end
        assert_response :unauthorized

        get "#{ROOT}/permission_sets"
        token = response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'same origin' } }, headers: { 'X-CSRF-Token' => token }
        assert_response :created, 'the same request with the page token is the legitimate one'
      end

      test 'CLAIMS-1 a forged POST authenticated by a plain cookie is refused, a bearer-token client is not' do
        PermissionForge.configuration.api_auth = ->(controller) { controller.request.cookie_jar['pf_rr_admin'] == '1' }
        cookies['pf_rr_admin'] = '1'
        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'forged' } }
        end
        assert_response :unauthorized

        PermissionForge.configuration.api_auth = ->(controller) { controller.request.headers['Authorization'] == 'Bearer s3cret' }
        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'token client' } }.to_json,
                                            headers: { 'Authorization' => 'Bearer s3cret', 'Content-Type' => 'application/json' }
        assert_response :created
      end

      # ---- #2 FALSE: "Remove all PermissionForge data for a user" -----------------

      test 'CLAIMS-2 the erasure task says what it removes and what stays' do
        rake = read('lib/tasks/permission_forge_gdpr.rake')

        assert_not_includes rake, 'Remove all PermissionForge data'
        assert_includes rake, 'Ids and other event data stay'
      end

      # ---- #4 FALSE: "RLS enforcement survives console access" ---------------------

      # Pinned: under the default nil_user_strategy :bypass the policy lets a
      # session without the session variable (console, psql, jobs) see every
      # row; only :deny / :raise close it. The docs must say so.
      test 'CLAIMS-4 limit: the RLS policy opens to a session without the user variable under nil_user_strategy :bypass' do
        bypass = PermissionForge::Configuration.new.tap { |c| c.nil_user_strategy = :bypass }
        deny = PermissionForge::Configuration.new.tap { |c| c.nil_user_strategy = :deny }

        open_policy = PermissionForge::Services::RlsPolicyGenerator.new(model_class: Customer, configuration: bypass).call[:statements].join
        closed_policy = PermissionForge::Services::RlsPolicyGenerator.new(model_class: Customer, configuration: deny).call[:statements].join

        assert_includes open_policy, ') IS NULL OR '
        assert_includes closed_policy, ') IS NOT NULL AND '
      end

      # ---- #5 FALSE: "user_active_check — used by the regenerator to skip deactivated users" ----

      test 'CLAIMS-5 limit: user_active_check removes no access by itself' do
        user = create_user(deactivated: true)
        create_permission_set_user(user: user, permission_set: readable_customer_set)

        assert_not PermissionForge.configuration.user_active_check.call(user)
        assert User.find(user.id).can_read?(:Customer), 'the audit reports it; revoking is the host\'s move'
      end

      test 'CLAIMS-5 the generated initializer no longer claims the regenerator skips inactive users' do
        template = render_install_template('initializer.rb.tt')

        assert_not_includes template, 'Used by the regenerator to skip deactivated users'
        assert_includes template, 'It does not remove access'
      end

      # ---- #8 PARTLY: "rules apply to find_by" ---------------------------------------

      # Pinned: only the class-level Model.find_by is overridden; a relation
      # or association find_by bypasses the rules unless auto_query_scoping
      # is on. The docs name the class-level methods.
      test 'CLAIMS-8 limit: a relation find_by bypasses row rules under auto_query_scoping :off, :filter_only closes it' do
        user = create_user
        set = readable_customer_set
        create_permission_set_user(user: user, permission_set: set)
        create_permission_set_rule(permission_set: set, resource: set.resources.sole, field_name: 'name', operator: 'equal',
                                   field_value: 'mine', include_nulls: false)
        theirs = create_customer(name: 'theirs')
        Current.user = User.find(user.id)

        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) { Customer.find_by(id: theirs.id) }
        assert_equal theirs, Customer.where(nil).find_by(id: theirs.id), 'documented: Relation#find_by is not rule-scoped'

        PermissionForge.configuration.auto_query_scoping = :filter_only
        assert_nil Customer.where(nil).find_by(id: theirs.id)
      end

      # ---- #9 PARTLY: "CRUD No -> Access Denied" --------------------------------------

      # Pinned: a granting resource's CRUD flags are enforced where the host
      # calls can_*? or uses ControllerActionGuard; a field row that grants
      # read is read. (Muting a resource's read does hide its fields: CORE-5.)
      test 'CLAIMS-9 limit: a granting resource with read_access false does not hide a field row that grants read' do
        user = create_user
        set = create_permission_set(name: 'Odd')
        resource = create_resource(permission_set: set, name: 'Customer', read_access: false)
        create_resource_field(resource: resource, name: 'name', read_access: true)
        create_permission_set_user(user: user, permission_set: set)
        user = User.find(user.id)

        assert_not user.can_read?(:Customer)
        assert_equal({ name: 'Acme' },
                     PermissionForge::Services::FiltersResponseAttributes.call(attributes: { name: 'Acme' }, resource_name: 'Customer', user: user))
      end

      # ---- #10 PARTLY: "a granting set cannot narrow what another grants" ------------

      test 'CLAIMS-10 limit: row rules intersect across granting sets' do
        user = create_user
        first = readable_customer_set(name: 'First')
        second = readable_customer_set(name: 'Second')
        [first, second].each { |set| create_permission_set_user(user: user, permission_set: set) }
        create_permission_set_rule(permission_set: first, resource: first.resources.sole, field_name: 'name', operator: 'equal',
                                   field_value: 'mine', include_nulls: false)
        create_permission_set_rule(permission_set: second, resource: second.resources.sole, field_name: 'domain', operator: 'equal',
                                   field_value: 'a.test', include_nulls: false)
        create_customer(name: 'mine', domain: 'a.test')
        create_customer(name: 'mine', domain: 'b.test')
        create_customer(name: 'theirs', domain: 'a.test')
        Current.user = User.find(user.id)

        assert_equal [%w[mine a.test]], Customer.permission_scoped.pluck(:name, :domain)
      end

      # ---- #11 FALSE: "generators for admin API scaffolding" -----------------------

      test 'CLAIMS-11 the generators that exist are install, upgrade and rls' do
        generators = Dir.children(File.join(GEM_ROOT, 'lib/generators/permission_forge')).sort

        assert_equal %w[install rls upgrade], generators
        assert_equal(%w[install rls upgrade], generators.select do |name|
          File.exist?(File.join(GEM_ROOT, 'lib/generators/permission_forge', name, "#{name}_generator.rb"))
        end)
      end

      test 'CLAIMS-11 the gemspec and README no longer claim admin API scaffolding' do
        assert_not_includes read('permission_forge.gemspec'), 'scaffolding'
        assert_not_includes read('README.md'), 'scaffold admin API'
      end

      # ---- #12 PARTLY/FALSE: "Includes Redis caching", "RedisCache + Oj" --------------

      test 'CLAIMS-12 there is no RedisCache backend: Redis is a Rails cache store through :rails_cache' do
        assert_not PermissionForge::Cache.const_defined?(:RedisCache, false)
        assert_not File.exist?(File.join(GEM_ROOT, 'lib/permission_forge/cache/redis_cache.rb'))
        assert_raises(ArgumentError) { PermissionForge::Configuration.new.tap { |c| c.cache_backend = :redis }.cache_store }
        assert_kind_of PermissionForge::Cache::RailsCache,
                       PermissionForge::Configuration.new.tap { |c| c.cache_backend = ActiveSupport::Cache::MemoryStore.new }.cache_store
      end

      test 'CLAIMS-12 the benchmarks doc and the gemspec no longer recommend RedisCache' do
        assert_no_match(/RedisCache(?!Store)/, read('docs/benchmarks.md'), 'RedisCacheStore is the Rails store; RedisCache was the dead backend')
        assert_not_includes read('permission_forge.gemspec'), 'Redis caching'
      end

      # ---- #14 PARTLY: "audit_events allowed only when the hook returns exactly true" ----

      test 'CLAIMS-14 limit: with audit_log_authorization unset anyone who passes api_auth reads the log' do
        ActionController::Base.allow_forgery_protection = false
        assert_nil PermissionForge.configuration.audit_log_authorization

        get "#{ROOT}/api/audit_events"
        assert_response :ok

        PermissionForge.configuration.audit_log_authorization = ->(_controller) { 'yes' }
        get "#{ROOT}/api/audit_events"
        assert_response :forbidden, 'set, only an exact true allows'
      end

      # ---- #15 PARTLY: "cached access never outlives the assignment" --------------------

      # The shared store is clamped to expires_at, so a fresh instance
      # denies; since CS-6 (pre-release review) the memo of a user instance
      # is retired at the expiry too.
      test 'CLAIMS-15 a memoized user instance stops granting at the expiry' do
        user = create_user
        create_permission_set_user(user: user, permission_set: readable_customer_set, expires_at: 2.seconds.from_now)
        held = User.find(user.id)
        assert held.can_read?(:Customer)

        travel 5.seconds do
          assert_not held.can_read?(:Customer), 'the instance that memoized before the expiry'
          assert_not User.find(user.id).can_read?(:Customer), 'a fresh instance'
          assert_not held.reload.can_read?(:Customer)
        end
      end

      # ---- #17 FALSE: "Log parameter filtering — opt-in" ------------------------------

      test 'CLAIMS-17 parameter filtering is on by default' do
        assert_equal true, PermissionForge::Configuration.new.filter_parameters_integration
        PermissionForge.configuration.gdpr_defaults = true # what the generated initializer asks hosts to choose
        assert_not_empty PermissionForge.gdpr_filter_parameters
      end

      test 'CLAIMS-17 the README says parameter filtering is on by default' do
        assert_not_includes read('README.md'), 'opt-in integration with `Rails.application.config.filter_parameters`'
        assert_includes read('README.md'), 'on by default'
      end

      # ---- #21 FALSE: "you must call regenerate_permissions" -------------------------

      test 'CLAIMS-21 an assignment takes effect without regenerate_permissions' do
        user = create_user
        assert_not User.find(user.id).can_read?(:Customer)

        create_permission_set_user(user: user, permission_set: readable_customer_set)

        assert User.find(user.id).can_read?(:Customer)
      end

      # ---- #32 / packaging M1: the generated initializer assumed Current and dropped uuid ----

      test 'CLAIMS-32 the generated initializer works without a Current class and keeps uuid in the profile' do
        template = render_install_template('initializer.rb.tt')

        assert_includes template, 'defined?(::Current)'
        assert_no_match(/^\s*config\.current_user_resolver = -> \{ Current\.user \}/, template)
        # The template leaves the profile to the default builder (which keeps uuid and leaves an
        # encrypted attribute out of the cached hash); the line is a commented example.
        assert_no_match(/^\s*config\.profile_builder =/, template)
        # Review of the round-7 fixes (P2-4): the example calls the public readers (they decrypt, and may be
        # masked), so its comment says how it differs from the default instead of calling itself the default.
        comment = template[/^ *# The profile cached.*?(?=^ *# config\.profile_builder)/m].to_s
        assert_no_match(/the default is this/i, comment)
        assert_match(/public readers.*decrypt/m, comment)
        profile = install_template_configuration.profile_builder.call(create_user(uuid: 'u-32', name: 'Ada', email: 'ada@example.com'))
        assert_equal({ id: profile[:id], uuid: 'u-32', name: 'Ada', email: 'ada@example.com' }, profile)
      end

      # ---- #35: README named `:mask`; the value is :mask_all ---------------------------

      test 'CLAIMS-35 :mask_all is an unconfigured-field strategy and :mask is not' do
        strategies = PermissionForge::Services::FiltersResponseAttributes::UNCONFIGURED_FIELD_STRATEGIES

        assert_includes strategies.keys, :mask_all
        assert_not_includes strategies.keys, :mask
        PermissionForge.configuration.unconfigured_field_strategy = :mask_all
        assert_equal({ name: PermissionForge::Services::MaskValue.call('Acme', strategy: 'full') },
                     PermissionForge::Services::FiltersResponseAttributes.call(attributes: { name: 'Acme' }, resource_name: 'Customer',
                                                                               user: create_user))
      end

      # ---- packaging B1 / M2: two LICENSE files, internal plans in docs/ -----------------

      test 'CLAIMS-PKG one LICENSE.txt ships and no internal plan documents' do
        assert_equal ['LICENSE.txt'], Dir.children(GEM_ROOT).grep(/\ALICENSE/)
        assert_empty Dir.children(File.join(GEM_ROOT, 'docs')).grep(/\A(plan|prd)-/)
      end
    end
  end
end
