# frozen_string_literal: true

module DocsApp
  # The generated initializer's Option A (Basic auth credentials from ENV)
  # with its commented audit_actor_resolver, uncommented as a reader would:
  # the admin answers under HTTP Basic, and the person signed in to the app
  # in the same browser is the actor of what they do there. Without the
  # resolver, or signed out, the actor is the Basic auth login.
  module OptionA
    # The generated initializer's commented lines, uncommented here.
    CREDENTIAL_LINES = [/^\s*# (config\.http_basic_auth_user\s*=.*)$/, /^\s*# (config\.http_basic_auth_password\s*=.*)$/].freeze
    RESOLVER_LINE = /^\s*# (config\.audit_actor_resolver\s*=.*)$/
    SETTINGS = %i[http_basic_auth_enabled http_basic_auth_user http_basic_auth_password base_controller_class audit_actor_resolver].freeze
    ENV_CREDENTIALS = { 'PF_ADMIN_USER' => 'docs-admin', 'PF_ADMIN_PASSWORD' => 'docs-admin-password' }.freeze

    module_function

    # @return [Hash] the actor of an admin view in each case, and Alice's id
    def run
      configuration = PermissionForge.configuration
      saved = SETTINGS.to_h { |name| [name, configuration.public_send(name)] }
      ENV.update(ENV_CREDENTIALS)
      outcomes.merge(alice: Fixtures.person(:alice).id.to_s)
    ensure
      saved&.each { |name, value| configuration.public_send(:"#{name}=", value) }
      ENV_CREDENTIALS.each_key { |key| ENV.delete(key) }
      Application.reload!
    end

    def outcomes
      apply!(CREDENTIAL_LINES)
      without_resolver = actor_of(Visitor.new.sign_in(:alice))
      apply!(CREDENTIAL_LINES + [RESOLVER_LINE])
      { without_resolver: without_resolver, signed_in: actor_of(Visitor.new.sign_in(:alice)), signed_out: actor_of(Visitor.new) }
    end

    # The lines evaluated from the generated initializer on the live
    # configuration; the admin inherits from ActionController::Base again,
    # as on a fresh install.
    def apply!(patterns)
      configuration = PermissionForge.configuration
      configuration.audit_actor_resolver = nil
      configuration.http_basic_auth_enabled = true
      configuration.base_controller_class = PermissionForge::Configuration.new.base_controller_class
      configurer = Object.new
      configurer.define_singleton_method(:config) { configuration }
      configurer.instance_eval(lines(patterns).join("\n"), Install.initializer)
      Application.reload!
    end

    def lines(patterns)
      source = File.read(Install.initializer)
      patterns.map { |pattern| source[pattern, 1] || raise("the generated initializer has no line #{pattern.source}") }
    end

    # Opens the audit log with the Basic auth credentials; the actor of the
    # audit.viewed event that view recorded.
    def actor_of(visitor)
      before = PermissionForge::AuditEvent.maximum(:id).to_i
      status = visitor.get('/permissions/audit', 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64(ENV_CREDENTIALS.values.join(':'))}").status
      event = PermissionForge::AuditEvent.where(event: 'audit.viewed').where('id > ?', before).order(:id).last
      { status: status, actor_type: event&.actor_type, actor_id: event&.actor_id, actor_label: event&.actor_label }
    end
  end
end
