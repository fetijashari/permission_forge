# frozen_string_literal: true

module DocsApp
  # One person's browser against the docs app (a Rack::Test session: cookies
  # kept, redirects followed by hand).
  class Visitor
    HOST = %r{\Ahttps?://[^/]+}

    def initialize
      @session = Rack::Test::Session.new(Rails.application)
    end

    def sign_in(name)
      post('/session', email_address: Fixtures.email(name), password: PASSWORD)
      self
    end

    def get(path, headers = {}) = request(:get, path, {}, headers)
    def post(path, params = {}, headers = {}) = request(:post, path, params, headers)
    def delete(path) = request(:delete, path)

    def request(verb, path, params = {}, headers = {})
      @session.send(verb, path, params, headers)
      last
    end

    def last = @session.last_response

    # Status and path of the last answer (its Location without the host).
    def hop = [last.status, last.location&.sub(HOST, '')]

    # Follows redirects from `path` up to `limit` hops: the statuses and
    # locations on the way, and whether it was still redirecting (a loop).
    def chain(path, limit: 6)
      get(path)
      hops = [hop]
      while last.redirect? && hops.size <= limit
        @session.follow_redirect!
        hops << hop
      end
      { hops: hops, looped: last.redirect? }
    end

    def json = JSON.parse(last.body)
  end

  # The denial flows the documentation describes, driven as requests once
  # every document has been applied (the handler, the forbidden template, the
  # SessionsController#new line, the wired scaffold, Admin::BaseController).
  module Scenarios
    FORBIDDEN_H1 = 'You are not allowed to see this page'
    CUSTOMERS_CONTROLLER = 'app/controllers/customers_controller.rb'
    ALL = %i[dave_signin signed_out_root reload_after_turbo_signin public_index_without_resume_session public_index_with_resume_session
             bob_opens_carols_customer bob_api_customers customers_json bob_edits_status sign_in_page_guarded option_b_admin
             permission_scoped_without_read name_taken seeds_under_strict option_a_audit_actor].freeze

    module_function

    def run
      option_b!
      ALL.to_h do |name|
        [name, begin
          public_send(name)
        rescue StandardError => e
          { error: "#{e.class}: #{e.message}", at: e.backtrace&.first(3) }
        end]
      end
    end

    # The docs app signs admins in with the app's own sign-in (admin-ui.md,
    # Option B): Admin::BaseController comes from that document's file= block.
    def option_b!
      PermissionForge.configuration.http_basic_auth_enabled = false
      PermissionForge.configuration.base_controller_class = '::Admin::BaseController'
      Application.reload!
    end

    def page(response)
      body = response.body
      { status: response.status, layout: body.include?('data-turbo-track'), sign_out: body.include?('Sign out'),
        forbidden_h1: body.include?(FORBIDDEN_H1) }
    end

    # Dave signs up, holds no set: the sign-in form sends him to the guarded
    # root, refused in the layout; Sign out lands on the form.
    def dave_signin
      dave = Visitor.new.sign_in(:dave)
      sign_in = dave.hop
      root = page(dave.get('/'))
      dave.delete('/session')
      sign_out = dave.hop
      form = dave.get('/session/new')
      { sign_in: sign_in, root: root, sign_out: sign_out, form_status: form.status, form_shown: form.body.include?('email_address') }
    end

    def signed_out_root
      Visitor.new.chain('/').merge(sign_in_form: Visitor.new.get('/session/new').status)
    end

    # After a Turbo sign-in the address bar shows /session/new: Reload asks
    # for the sign-in page while signed in.
    def reload_after_turbo_signin
      dave = Visitor.new.sign_in(:dave)
      dave.chain('/session/new').merge(page(dave.last))
    end

    def public_index_without_resume_session
      with_public_index(resume_session: false) { Visitor.new.sign_in(:bob).then { |bob| bob.chain('/').merge(page(bob.last)) } }
    end

    def public_index_with_resume_session
      with_public_index(resume_session: true) do
        bob = Visitor.new.sign_in(:bob)
        bob.chain('/').merge(page(bob.last)).merge(masked: masked?(bob.last.body, 'acme@example.test'), rows: rows(bob.last.body))
      end
    end

    # The docs' CustomersController with its index opened to signed-out
    # visitors (docs/controller-actions.md#callback-order), with or without
    # the session resumed ahead of the guard.
    def with_public_index(resume_session:)
      path = File.join(Application.root, CUSTOMERS_CONTROLLER)
      original = File.read(path)
      lines = ['  allow_unauthenticated_access only: :index # a public index']
      lines << '  prepend_before_action :resume_session, only: :index # Current.user for a signed-in visitor' if resume_session
      File.write(path, original.sub(/^class CustomersController < ApplicationController\n/) { |head| "#{head}#{lines.join("\n")}\n" })
      Application.reload!
      yield
    ensure
      File.write(path, original)
      Application.reload!
    end

    def masked?(body, raw) = !body.include?(raw) && body.include?('***')
    def rows(body) = Fixtures::CUSTOMERS.map(&:first).select { |name| body.include?(name) }

    # Bob opens a customer Carol owns: the rule's own message on the 403 page,
    # in the layout; his own customer opens.
    def bob_opens_carols_customer
      bob = Visitor.new.sign_in(:bob)
      denied = bob.get("/customers/#{Fixtures.customer('Globex').id}")
      page(denied).merge(reason: denied.body.include?('Only your own customers'), own: bob.get("/customers/#{Fixtures.customer('Acme').id}").status)
    end

    # The same through the documented Api::BaseController: the JSON envelope
    # with the denying rule's message; his own customer, masked.
    def bob_api_customers
      bob = Visitor.new.sign_in(:bob)
      denied = bob.get("/api/customers/#{Fixtures.customer('Globex').id}")
      denied_json = { status: denied.status, body: bob.json }
      own = bob.get("/api/customers/#{Fixtures.customer('Acme').id}")
      { denied: denied_json, own: { status: own.status, name: bob.json['name'], masked: masked?(own.body, 'acme@example.test') } }
    end

    # The scaffold's JSON through the documented jbuilder partial.
    def customers_json
      bob = Visitor.new.sign_in(:bob)
      response = bob.get('/customers.json')
      { status: response.status }.merge(json_summary(bob.json))
    end

    def json_summary(records)
      acme = records.find { |record| record['name'] == 'Acme' } || {}
      { names: records.map { |record| record['name'] }, keys: acme.keys.sort, email_masked: masked?(acme['email'].to_s, 'acme@example.test'),
        notes: acme['notes'], phone: acme['phone'] }
    end

    # The wired scaffold's customer_params goes through PermitsAttributes: Bob
    # may edit the name, not the status (no row) nor the email (read-only).
    def bob_edits_status
      acme = Fixtures.customer('Acme')
      bob = Visitor.new.sign_in(:bob)
      bob.request(:patch, "/customers/#{acme.id}", customer: { name: 'Acme Ltd', status: 'closed', email: 'new@example.test' })
      saved = PermissionForge.without_permission_scope { Customer.find(acme.id) }
      { status: bob.hop, name: saved.read_attribute_before_type_cast(:name), status_column: saved.read_attribute_before_type_cast(:status),
        email: saved.read_attribute_before_type_cast(:email) }
    end

    # The guard in ApplicationController reaches SessionsController unless the
    # initializer excludes it.
    def sign_in_page_guarded
      configuration = PermissionForge.configuration
      excluded = configuration.controller_discovery_exclude
      configuration.controller_discovery_exclude = PermissionForge::Configuration::ControllerActionSettings::DEFAULT_CONTROLLER_DISCOVERY_EXCLUDE.dup
      guarded = page(Visitor.new.get('/session/new'))
      configuration.controller_discovery_exclude = excluded
      { without_exclusion: guarded, with_exclusion: Visitor.new.get('/session/new').status, excluded: Array(excluded).map(&:to_s) }
    end

    def option_b_admin
      { signed_out: Visitor.new.chain('/permissions', limit: 1)[:hops].first,
        bob: Visitor.new.sign_in(:bob).tap { |bob| bob.get('/permissions') }.hop,
        alice: Visitor.new.sign_in(:alice).get('/permissions').status }
    end

    # Erin's set has a rule and no read on Customer: permission_scoped still
    # answers her rows; the guard (REST: index → read) refuses the page.
    def permission_scoped_without_read
      erin = Fixtures.person(:erin)
      Current.session = erin.sessions.create!(ip_address: '127.0.0.1', user_agent: 'docs app')
      rows = Customer.permission_scoped.pluck(:name)
      can_read = erin.can_read?(:Customer)
      Current.reset
      { rows: rows, can_read: can_read, index_status: Visitor.new.sign_in(:erin).get('/customers').status }
    end

    # README step 4 after an admin made a "Sales Team" (ReadmeAgain).
    def name_taken = ReadmeAgain.name_taken

    # Under config.preset = :strict a seed with nobody signed in sees no
    # protected rows: find_or_create_by! duplicates unless the seed runs in
    # without_permission_scope.
    def seeds_under_strict
      Current.reset
      PermissionForge.configuration.preset = :strict
      { bare: seed_twice('Seeded Co'), wrapped: PermissionForge.without_permission_scope { seed_twice('Seeded Inc') },
        nil_user_strategy: PermissionForge.configuration.nil_user_strategy.to_s }
    ensure
      PermissionForge.configuration.preset = :compat
    end

    # The generated initializer's Option A with its audit_actor_resolver (docs_app/option_a.rb).
    def option_a_audit_actor = OptionA.run

    # A seed's find_or_create_by!, run twice; how many rows it left.
    def seed_twice(name)
      owner = Fixtures.person(:bob)
      2.times { Customer.find_or_create_by!(name: name, owner: owner) }
      PermissionForge.without_permission_scope { Customer.where(name: name).count }
    end
  end

  # The README's program run again, on the database as installed (nobody
  # holds a set): after an admin made a "Sales Team", once the name is free,
  # and without step 4's assignment line.
  module ReadmeAgain
    # README step 4's assignment line.
    ASSIGNMENT = /^PermissionForge::PermissionSetUser\.create!.*\n/

    module_function

    # README step 4 after an admin made a "Sales Team": the error the README
    # warns about, then the same lines once the name is free. On the app as
    # installed (nobody holds a set): step 5's claims hold because step 4
    # assigned the set, and fail when it did not.
    def name_taken
      as_installed do
        PermissionForge::PermissionSet.create!(name: 'Sales Team', is_active: true)
        first = readme_blocks
        PermissionForge::PermissionSet.find_by!(name: 'Sales Team').destroy!
        second = readme_blocks
        { taken: errors_of(first), retried: errors_of(second), claims: claims_of(second) }
      end.merge(without_assignment: as_installed { claims_of(readme_blocks(without: ASSIGNMENT)) })
    end

    # The block run on the database as installed; the scenarios' database put back after.
    def as_installed
      Database.snapshot!(:scenarios)
      Database.restore!
      yield
    ensure
      Database.restore!(:scenarios)
    end

    # The README's program once more, on the database as it is; `without`
    # takes a line out of the run blocks that have it.
    def readme_blocks(without: nil)
      readme = DocsApp.documents.find { |document| document.file == 'README.md' }
      readme = DocBlocks::Document.new(file: readme.file, blocks: readme.blocks.map { |block| cut(block, without) }) if without
      Programs.run_document(readme, fresh: false)[:blocks]
    end

    def cut(block, line)
      return block unless block.run? && block.body.match?(line)

      block.dup.tap { |copy| copy.body = block.body.sub(line, "\n") }
    end

    def errors_of(blocks) = blocks.filter_map { |block| block[:error] }

    def claims_of(blocks) = blocks.flat_map { |block| Array(block[:expectations]) }.map { |claim| claim[:passed] }
  end
end
