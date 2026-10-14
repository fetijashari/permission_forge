# frozen_string_literal: true

require 'test_helper'
require 'pp'
require_relative '../nested_attribute_models'

# A subclass of a protected model on the same table (no type column, as the
# review's probe had it): the attacker's way around rules and masks that
# name the base class.
class PfRrVipCustomer < Customer
end

module PermissionForge
  module ReleaseReadiness
    # The pre-release review of 2026-10-12, core-security lane. One test per finding, written from the attacker's or
    # the failing user's side, through the public entry points: the getters,
    # as_json, find_by, permission_scoped, FiltersResponseAttributes,
    # PermitsAttributes, the policy generator and HTTP requests. Each test
    # failed on v0.13.0 unless it is named as a limit.
    class CoreSecurityRegressionTest < ActiveSupport::TestCase
      class GuardedCustomer < ::Customer
        include PermissionForge::Concerns::MaskedAttributes

        def self.name = 'Customer'
      end

      SECRET = 'secret@acme.com'
      MASKED = 's***@acme.com'

      setup do
        @user = create_user
      end

      # A granting (or muting) set of the user with a Customer resource and
      # field rows; sets merge in creation order, so each gets a later
      # created_at than the one before.
      def grant(set: {}, resource: {}, fields: {})
        @grants = (@grants || 0) + 1
        permission_set = create_permission_set(name: "Set #{@grants}", created_at: 1.hour.ago + @grants.minutes, **set)
        create_permission_set_user(user: @user, permission_set: permission_set)
        row = create_resource(permission_set: permission_set, name: 'Customer', read_access: true, **resource)
        fields.each { |name, attrs| create_resource_field(resource: row, name: name.to_s, label: name.to_s, **attrs) }
        permission_set
      end

      def sign_in
        Current.user = User.find(@user.id)
      end

      def guarded_customer(**attrs)
        record = GuardedCustomer.create!({ uuid: SecureRandom.uuid, name: 'Acme', email: SECRET, domain: 'acme.com' }.merge(attrs))
        GuardedCustomer.find(record.id)
      end

      def filtered(attributes, resource_name: 'Customer')
        PermissionForge::Services::FiltersResponseAttributes.call(attributes: attributes, resource_name: resource_name,
                                                                  user: Current.user)
      end

      def permitted(params, resource: Customer)
        PermissionForge::Services::PermitsAttributes.call(resource: resource, permitted_params: params)
      end

      # ---- #1 BLOCKER: masked + hidden across two granting sets ----------------------

      # Set "Support" shows the email masked; an admin adds the user to a
      # "Baseline" set where the email is Hidden (read=f, mask=f, as the admin
      # UI writes Hidden). Picking the stricter level must never turn the mask
      # off, whichever set is older.
      test 'CORE-1 masked plus hidden across two sets never shows plaintext' do
        masked = { read_access: true, mask_access: true, mask_strategy: 'email' }
        hidden = { read_access: false, mask_access: false }
        [[masked, hidden], [hidden, masked]].each do |order|
          @user = create_user
          PermissionForge.configuration.unconfigured_field_strategy = :block
          order.each { |attrs| grant(fields: { email: attrs }) }
          sign_in
          customer = guarded_customer

          assert_equal MASKED, customer.email, "getter, order #{order.inspect}"
          assert_equal MASKED, customer.as_json['email'], "as_json, order #{order.inspect}"
          assert_equal MASKED, filtered({ email: SECRET })[:email], "response filter, order #{order.inspect}"
          assert_not_includes customer.to_json, SECRET
        end
      end

      # ---- #2 MAJOR: conditional sets cached per user, not per context ----------------

      # The victim's MFA-verified session builds the hash; an attacker holding
      # only the password opens a second session of the same user, with no
      # MFA flag, within conditional_set_cache_ttl.
      test 'CORE-2 an MFA-gated grant is not served to a session without the flag' do
        grant(set: { requires_session_flag: 'mfa_verified' }, resource: { read_access: true, delete_access: true })
        context = { session_flags: ['mfa_verified'], ip: '10.0.0.1' }
        PermissionForge.configuration.request_context_resolver = -> { context }
        verified_session = User.find(@user.id)
        assert verified_session.can_delete?(:Customer), 'the MFA session itself'

        context = { session_flags: [], ip: '10.0.0.1' }
        assert_not User.find(@user.id).can_delete?(:Customer), 'a second session of the same user, no MFA flag, new instance'
        assert_not verified_session.can_delete?(:Customer), 'the same instance once its context lost the flag (memo retired)'

        context = { session_flags: ['mfa_verified'], ip: '10.0.0.1' }
        assert User.find(@user.id).can_delete?(:Customer), 'the flag back: the grant is back'
      end

      test 'CORE-2 an IP-restricted grant built from the office is not served to a remote request' do
        grant(set: { allowed_ips: '10.0.0.0/8' }, resource: { read_access: true, delete_access: true })
        context = { ip: '10.1.2.3' }
        PermissionForge.configuration.request_context_resolver = -> { context }
        assert User.find(@user.id).can_delete?(:Customer), 'office'

        context = { ip: '203.0.113.9' }
        assert_not User.find(@user.id).can_delete?(:Customer), 'remote, same user, within the TTL'
      end

      # A background job (no request context, non-strict default) reads the
      # hash first: that must not hand the IP-gated grant to the next web
      # request from outside the allowlist.
      test 'CORE-2 a job with no context does not pre-build the grant for a remote web request' do
        grant(set: { allowed_ips: '10.0.0.0/8' }, resource: { read_access: true, delete_access: true })
        context = {}
        PermissionForge.configuration.request_context_resolver = -> { context }
        User.find(@user.id).can_delete?(:Customer) # the job (documented: a blank context applies every conditional set)

        context = { ip: '203.0.113.9' }
        assert_not User.find(@user.id).can_delete?(:Customer), 'the web request after the job'
      end

      # The admin tightens the condition (MFA → hardware key) after the user's
      # session built and memoized the MFA variant: the instance in flight
      # and every new one must lose the grant at once (WS4 review R1).
      test 'CORE-2 tightening a condition revokes a grant already built and memoized under the old one' do
        set = grant(set: { requires_session_flag: 'mfa_verified' }, resource: { read_access: true, delete_access: true })
        context = { session_flags: ['mfa_verified'], ip: '10.0.0.1' }
        PermissionForge.configuration.request_context_resolver = -> { context }
        session = User.find(@user.id)
        assert session.can_delete?(:Customer)

        set.update!(requires_session_flag: 'hardware_key')

        assert_not session.can_delete?(:Customer), 'the instance that memoized the MFA variant'
        assert_not User.find(@user.id).can_delete?(:Customer), 'a new instance'
        context = { session_flags: %w[mfa_verified hardware_key], ip: '10.0.0.1' }
        assert User.find(@user.id).can_delete?(:Customer), 'the new condition met'
      end

      # ---- #3 MAJOR: a subclass of a protected model ignores the parent's rules ----

      # The rule "only my customers" is on the Customer resource. The attacker
      # queries through VipCustomer < Customer (same table): every row-level
      # path must still apply the Customer rules, and the Customer field
      # permissions must still mask through the subclass.
      test 'CORE-3 an STI subclass cannot be used to dodge the parent resource rules or masks' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        set = grant(fields: { name: { read_access: true }, email: { read_access: true, mask_access: true, mask_strategy: 'email' } })
        create_permission_set_rule(permission_set: set, resource: set.resources.sole, field_name: 'name', operator: 'equal',
                                   field_value: 'mine', include_nulls: false)
        create_customer(name: 'mine', email: SECRET)
        theirs = create_customer(name: 'theirs', email: SECRET)
        sign_in

        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) { Customer.find_by(id: theirs.id) }
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) { PfRrVipCustomer.find_by(id: theirs.id) }
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) { PfRrVipCustomer.find_by!(id: theirs.id) }
        assert_equal %w[mine], PfRrVipCustomer.permission_scoped.pluck(:name)
        assert_equal MASKED, PfRrVipCustomer.find(theirs.id).email, 'the Customer mask applies through the subclass'

        PermissionForge.configuration.auto_query_scoping = :filter_only
        assert_equal %w[mine], Customer.all.pluck(:name)
        assert_equal %w[mine], PfRrVipCustomer.all.pluck(:name), 'the auto scope through the subclass'
      ensure
        PermissionForge.configuration.auto_query_scoping = :off
      end

      # ---- #4 MAJOR: PermitsAttributes lets shaped values through ------------------

      # The user may edit Customer#name only. The host's strong params admit
      # json-shaped values (permit!, `col: {}`): a non-editable key whose
      # value is a Hash, an Array of Hashes, or a `*_attributes` payload for
      # a model the user was never granted, must all be dropped.
      test 'CORE-4 PermitsAttributes drops a non-editable key whatever the shape of its value' do
        grant(resource: { edit_access: true },
              fields: { name: { read_access: true, edit_access: true }, email: { read_access: true, edit_access: false } })
        sign_in
        params = ActionController::Parameters.new(
          name: 'ok', email: { name: 'attacker@x' }, domain: [{ name: 'a' }, 'evil.com'],
          settings_attributes: { name: 'not an association' }
        ).permit!

        assert_equal({ 'name' => 'ok' }, permitted(params, resource: PfNestedCustomer))
      end

      test 'CORE-4 a nested payload for a child model the user was never granted is dropped, not filtered by the parent' do
        grant(resource: { edit_access: true }, fields: { name: { read_access: true, edit_access: true } })
        sign_in
        params = ActionController::Parameters.new(name: 'x', supplier_attributes: { name: 'pwned' }).permit!

        assert_equal({ 'name' => 'x' }, permitted(params, resource: PfNestedCustomer))
        assert_equal false, PermissionForge::Configuration.new.nested_attributes_parent_fallback, 'the shipped default'
      end

      test 'CORE-4 non-record elements inside a nested collection payload are dropped' do
        grant(resource: { edit_access: true }, fields: { name: { read_access: true, edit_access: true } })
        supplier_set = create_permission_set(name: 'Suppliers')
        create_permission_set_user(user: @user, permission_set: supplier_set)
        supplier = create_resource(permission_set: supplier_set, name: 'Supplier', read_access: true, edit_access: true)
        create_resource_field(resource: supplier, name: 'name', read_access: true, edit_access: true)
        sign_in
        params = ActionController::Parameters.new(contacts_attributes: [{ name: 'fine' }, 'evil.com', 42]).permit!

        assert_equal({ 'contacts_attributes' => [{ 'name' => 'fine' }] }, permitted(params, resource: PfNestedCustomer))
      end

      # ---- #5 MAJOR: muting a resource's read leaves its fields readable ---------

      # An "Offboarding" muting set revokes Customer read. can_read? says no;
      # the getters, as_json, the response filter and the write path must say
      # no too — muting read must protect at least as much as never granting.
      test 'CORE-5 muting a resource read hides every field on every read and write path' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        grant(resource: { edit_access: true },
              fields: { name: { read_access: true, edit_access: true }, email: { read_access: true, edit_access: true } })
        grant(set: { is_muting: true, name: 'Offboarding' }, resource: { read_access: true })
        sign_in
        customer = guarded_customer

        assert_not Current.user.can_read?(:Customer)
        assert_nil customer.email
        assert_nil customer.name
        assert_not customer.as_json.key?('email')
        assert_not_includes customer.to_json, SECRET
        assert_empty filtered({ name: 'Acme', email: SECRET })
        assert_empty permitted({ 'name' => 'x', 'email' => 'y' })
      end

      # ---- #6 MAJOR: RLS view_all bypass ignores Resource.is_active and the tenant ----

      # Opt-in PostgreSQL RLS: an admin deactivates the view_all resource row
      # to revoke the bypass. The app layer stops bypassing; the policy text
      # (checked here, not executed — the PostgreSQL run lives in test/rls)
      # must require the row to be active and in the protected row's tenant.
      test 'CORE-6 the generated RLS view_all bypass requires an active resource row of the same tenant' do
        set = grant(resource: { view_all: true })
        create_permission_set_rule(permission_set: set, resource: set.resources.sole)

        policy = PermissionForge::Services::RlsPolicyGenerator.new(model_class: Customer).call
        view_all_checks = policy[:statements].join("\n").split('EXISTS (').select { |chunk| chunk.include?('r.view_all = TRUE') }

        assert_operator view_all_checks.size, :>=, 2, 'a granting and a muting view_all check per policy'
        view_all_checks.each do |check|
          assert_includes check, 'r.is_active = TRUE'
          assert_match(/AND r\.["`]?account_id["`]? = ["`]?customers["`]?\.["`]?account_id["`]?/, check)
        end
        assert_operator PermissionForge::Services::RlsPolicyGenerator::GENERATOR_VERSION, :>=, 5, 'installs re-sync'
      end

      test 'CORE-6 deactivating a view_all resource row revokes the bypass in the app layer' do
        set = grant(resource: { view_all: true })
        create_permission_set_rule(permission_set: set, resource: set.resources.sole, field_name: 'name', operator: 'equal',
                                   field_value: 'mine', include_nulls: false)
        create_customer(name: 'mine')
        create_customer(name: 'theirs')
        sign_in
        assert_equal %w[mine theirs].sort, Customer.permission_scoped.pluck(:name).sort

        set.resources.sole.update!(is_active: false)
        sign_in

        assert_not Current.user.can_view_all?(:Customer)
        assert_not Current.user.can_read?(:Customer), 'an inactive resource row grants nothing'
      end

      # ---- #7 MINOR: inspect prints raw masked and hidden values ------------------

      # A record lands in a log line or an error report: inspect and
      # pretty_print must show what the getters show.
      test 'CORE-7 inspect and pretty_print never print a masked or hidden value' do
        grant(fields: { name: { read_access: true }, email: { read_access: true, mask_access: true, mask_strategy: 'email' },
                        domain: { read_access: false } })
        sign_in
        customer = guarded_customer(domain: 'hidden.example')

        [customer.inspect, customer.pretty_inspect, "failed: #{customer.inspect}", [customer].inspect].each do |text|
          assert_not_includes text, SECRET
          assert_not_includes text, 'hidden.example'
        end
        assert_includes customer.inspect, MASKED
      end

      # ---- #8 MINOR: strict mode drops conditional muting sets ----------------------

      # Strict mode is "fail closed when there is no context": it must drop
      # conditional grants and keep a conditional lockdown.
      test 'CORE-8 strict mode without a context keeps a conditional muting set' do
        grant(resource: { read_access: true, delete_access: true })
        grant(set: { is_muting: true, name: 'Lockdown', requires_session_flag: 'never_set' },
              resource: { read_access: false, delete_access: true })
        PermissionForge.configuration.request_context_resolver = -> { {} }
        assert_not User.find(@user.id).can_delete?(:Customer), 'non-strict: the lockdown applies'

        PermissionForge.cache.clear
        PermissionForge.configuration.conditional_sets_strict_mode = true

        assert_not User.find(@user.id).can_delete?(:Customer), 'strict: the lockdown still applies'
      end

      # The documented resolver gives a job `{ ip: nil, session_flags: [],
      # time: }`: under strict mode that is no context (the lockdown holds,
      # the MFA grant is dropped), while session flags alone — a web request
      # behind a misconfigured proxy — are a context, judged per set (WS4
      # review R3, N6).
      test 'CORE-8 strict mode: a job cannot lift a lockdown or earn an MFA grant, a request with flags alone is judged per set' do
        PermissionForge.configuration.conditional_sets_strict_mode = true
        grant(resource: { read_access: true, delete_access: true })
        grant(set: { is_muting: true, name: 'Kiosk lockdown', allowed_ips: '192.0.2.0/24' },
              resource: { read_access: false, delete_access: true })
        grant(set: { requires_session_flag: 'mfa_verified' }, resource: { read_access: true, create_access: true })
        context = { ip: nil, session_flags: [], time: Time.current }
        PermissionForge.configuration.request_context_resolver = -> { context }

        job = User.find(@user.id)
        assert_not job.can_delete?(:Customer), 'the lockdown applies to the job'
        assert_not job.can_create?(:Customer), 'the MFA grant is not handed to the job'

        context = { ip: nil, session_flags: ['mfa_verified'] }
        request = User.find(@user.id)
        assert request.can_create?(:Customer), 'flags alone are a context: the MFA set passes'
        assert_not request.can_delete?(:Customer), 'the IP lockdown cannot be judged without an IP: it applies (CS-3)'
      end

      # Pre-release review core-security #3 (CS-3): with flags but no IP (a
      # proxy that strips it, a resolver reading the wrong header) strict
      # mode lifted an IP-gated lockdown: a missing context must never lift
      # one. A granting set is still judged as it is, and so is everything
      # without strict mode.
      test 'CS-3 strict mode: a muting set whose condition cannot be judged applies; granting sets and non-strict mode are unchanged' do
        grant(resource: { read_access: true, delete_access: true })
        grant(set: { is_muting: true, name: 'Kiosk lockdown', allowed_ips: '192.0.2.0/24' },
              resource: { read_access: false, delete_access: true })
        grant(set: { is_muting: true, name: 'Impersonation', requires_session_flag: 'impersonating' },
              resource: { read_access: false, create_access: true })
        grant(set: { name: 'Office', allowed_ips: '192.0.2.0/24' }, resource: { read_access: true, edit_access: true })
        grant(resource: { read_access: true, create_access: true })
        context = { ip: '', session_flags: ['mfa_verified'] }
        PermissionForge.configuration.request_context_resolver = -> { context }
        PermissionForge.configuration.conditional_sets_strict_mode = true

        request = User.find(@user.id)
        assert_not request.can_delete?(:Customer), 'the IP lockdown applies without an IP'
        assert request.can_create?(:Customer), 'flags were given: the impersonation lockdown is judged, and fails'
        assert_not request.can_edit?(:Customer), 'the IP-gated grant is not given without an IP'

        context = { ip: '198.51.100.7' }
        assert_not User.find(@user.id).can_create?(:Customer), 'no flags at all: the flag-gated lockdown applies'
        assert User.find(@user.id).can_delete?(:Customer), 'an IP outside the range: the lockdown is judged, and fails'

        PermissionForge.configuration.conditional_sets_strict_mode = false
        context = { ip: '', session_flags: ['mfa_verified'] }
        assert User.find(@user.id).can_delete?(:Customer), 'without strict mode an IP condition without an IP fails, as before'
      end

      # Pre-release review core-security #6 (CS-6): the store entry's TTL is
      # clamped to the assignment's expires_at, but a user instance kept
      # across requests (a long-lived job, a console, a cached Current.user)
      # kept the memoized hash and its grant past the expiry.
      test 'CS-6 a kept user instance stops granting when its assignment ends' do
        set = create_permission_set(name: 'Temporary')
        create_permission_set_user(user: @user, permission_set: set, expires_at: 1.hour.from_now)
        create_resource(permission_set: set, name: 'Customer', read_access: true, delete_access: true)
        kept = User.find(@user.id)
        assert kept.can_delete?(:Customer)
        assert_equal %i[permissions preferences profile], kept.permissions_hash.keys.sort, 'the expiry is not part of the hash'

        travel 61.minutes
        assert_not kept.can_delete?(:Customer), 'the memo outlived the assignment'
        assert_not User.find(@user.id).can_delete?(:Customer)
      end

      test 'CS-6 a kept instance whose hash came from the store also stops at the expiry' do
        set = create_permission_set(name: 'Temporary')
        create_permission_set_user(user: @user, permission_set: set, expires_at: 1.hour.from_now)
        create_resource(permission_set: set, name: 'Customer', read_access: true, delete_access: true)
        User.find(@user.id).permissions_hash # cached by another request
        kept = User.find(@user.id)
        assert kept.can_delete?(:Customer), 'read from the store'

        travel 61.minutes
        assert_not kept.can_delete?(:Customer)
      end

      # ---- #9 MINOR: virtual fields get an implicit edit for read-only users ------

      test 'CORE-9 a declared virtual field is not writable for a user whose resource grants no edit' do
        grant(resource: { edit_access: false }, fields: { name: { read_access: true, edit_access: false } })
        sign_in

        assert_not Current.user.can_edit?(:Customer)
        assert_equal false, Current.user.field_permissions(:Customer, :full_address)[:edit_access]
        assert_empty permitted({ 'name' => 'x', 'full_address' => 'y', 'contact_count' => 9 })
      end

      # ---- #10 MINOR, documented limit: the row layer ignores resource access -----

      # "No rules means no restriction": a user with no Customer entry at all
      # gets every row through permission_scoped. Documented in
      # docs/row-level-rules.md; a host checks can_read? as well.
      test 'CORE-10 limit: without a resource entry the row layer returns every row while can_read? is false' do
        create_customer(name: 'mine')
        create_customer(name: 'theirs')
        sign_in

        assert_not Current.user.can_read?(:Customer)
        assert_equal %w[mine theirs].sort, Customer.permission_scoped.pluck(:name).sort
      end

      # ---- code-quality #2: NotAuthorizedError#message was an Array ----------------

      test 'CORE-CQ2 NotAuthorizedError#message is a String and #details keeps the structure' do
        set = grant
        create_permission_set_rule(permission_set: set, resource: set.resources.sole, field_name: 'name', operator: 'equal',
                                   field_value: 'mine', failure_message: 'Not your customer', include_nulls: false)
        theirs = create_customer(name: 'theirs')
        sign_in

        error = assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) { Customer.find_by(id: theirs.id) }

        assert_kind_of String, error.message
        assert_includes error.message, 'Not your customer'
        assert_kind_of Array, error.details
        assert_includes error.details.sole, 'Not your customer'
      end
    end

    # The fail-open note of the core-security report: nil_user_strategy
    # covered jobs and HTTP alike, so a host could not refuse signed-out
    # requests to guarded controller actions without also closing record
    # lookups in jobs.
    class CoreSecurityGuardRegressionTest < ActionDispatch::IntegrationTest
      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @old_resolver = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.current_user_resolver = -> {}
        set = create_permission_set(name: 'Support')
        create_resource(permission_set: set, name: 'Customer', read_access: true)
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      test 'CORE-FO1 a signed-out request to a guarded action can be refused without touching nil_user_strategy' do
        PermissionForge.configuration.action_guard_nil_user_strategy = :deny

        get '/customers'

        assert_response :forbidden
        assert_equal :bypass, PermissionForge.configuration.nil_user_strategy
        assert_match(/^  config\.action_guard_nil_user_strategy = :deny$/, render_install_template('initializer.rb.tt'),
                     'new installs refuse signed-out guarded requests')
      end

      test 'CORE-FO1 limit: the shipped default still follows nil_user_strategy (:bypass) for existing hosts' do
        assert_nil PermissionForge::Configuration.new.action_guard_nil_user_strategy

        get '/customers'

        assert_response :ok
      end
    end
  end
end
