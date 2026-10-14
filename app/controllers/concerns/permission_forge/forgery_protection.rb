module PermissionForge
  # How the admin screens and the admin API verify a mutating request. Rails
  # 8.2 checks the browser's Sec-Fetch-Site header, and `load_defaults 8.2`
  # selects `:header_only`, which lets a plain-HTTP request that carries no
  # such header through without any check — a forged request from a browser
  # that does not send it, or to an app served over HTTP. The engine's
  # controllers use `:header_or_legacy_token` whatever the host chose: the
  # header decides when the browser sends it (same-origin and same-site pass
  # without a token, cross-site is refused), and without it the authenticity
  # token is required, as on every earlier Rails. Rails before 8.2 has no
  # such choice and always checks the token.
  #
  # @api private
  module ForgeryProtection
    extend ActiveSupport::Concern

    STRATEGY = :header_or_legacy_token

    class_methods do
      # The engine's verification strategy as protect_from_forgery options,
      # empty where Rails offers no choice. Each controller calls
      # protect_from_forgery itself with its own `with:`, so the call stays
      # visible (and Brakeman sees it).
      def pf_forgery_strategy
        respond_to?(:forgery_protection_verification_strategy) ? { using: STRATEGY } : {}
      end
    end
  end
end
