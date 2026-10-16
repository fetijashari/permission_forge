# frozen_string_literal: true

module PermissionForge
  module Audit
    # The actor labels the gem writes on an event itself, stored as codes
    # (never English), each for one actor type: the admin names them from
    # the locale (`permission_forge.audit_log.actor_codes.<code>`,
    # Admin::ActorLabel). A label a person or the host chose is shown as
    # stored; so is a code under another actor type (a person called "boot").
    #
    # @api private
    module ActorCodes
      # An API request nobody named (api_auth said yes, but not who): ActorResolver's fallback.
      API_CLIENT = 'api_client'
      # The settings observer, which records the audit settings as the application boots.
      BOOT = 'boot'
      # actor type => the codes it carries.
      BY_TYPE = { 'api' => [API_CLIENT], 'system' => [BOOT] }.freeze
      # A label stored before it was a code => the code.
      LEGACY = { 'API client' => API_CLIENT }.freeze

      # @param type [String, Symbol] the event's actor_type
      # @param label [String, nil] the event's actor_label
      # @return [String, nil] the code the label stands for, nil for any other label
      def self.code(type, label)
        code = label.to_s.strip
        code = LEGACY.fetch(code, code)
        code if BY_TYPE.fetch(type.to_s, []).include?(code)
      end
    end
  end
end
