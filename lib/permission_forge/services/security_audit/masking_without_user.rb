# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # ConfigCheck's findings about masking with nobody signed in
      # (masked_attributes_nil_user_strategy) and about the request marker
      # they depend on (WebRequest): included by ConfigCheck, which lists
      # them in its RULES.
      #
      # @api private
      module MaskingWithoutUser
        private

        # The one nil-user setting that is about the getters themselves.
        # :bypass is reported with :hide_in_requests as the remedy; under
        # :hide_in_requests what still reads as stored (jobs, the console) is
        # an info; :hide reports nothing here (UserModelCheck notes the user
        # model's exemption).
        def masked_nil_user_bypass
          case configuration.masked_attributes_nil_user_strategy
          when :bypass then masked_nil_user_bypassed
          when :hide_in_requests then masked_nil_user_outside_requests
          end
        end

        def masked_nil_user_bypassed
          finding(:medium, :masked_nil_user_bypass, 'Masked attributes are readable with no current user',
                  'masked_attributes_nil_user_strategy is :bypass: when nobody is signed in the getters, attributes ' \
                  'and as_json of a masked model return the stored values, whatever nil_user_strategy says — in a job, ' \
                  'a mailer or the console, and also in a web request where nobody is signed in (a public page, a ' \
                  'webhook, a controller that forgot authentication, a resolver that returns nil). Each such read in ' \
                  'a web request is logged (once per model and process) and published as field.unmasked_without_user ' \
                  '(stored when audit_runtime_events includes :bypass). Set it to :hide_in_requests: hidden in web ' \
                  'requests with nobody signed in, the stored values kept for jobs, rake and the console. Trade-off: ' \
                  'a page that reads a masked model before anyone signs in (a tenant lookup, a public page, a mail ' \
                  'sent with deliver_now) then reads hidden values: sign the request in first, or read raw columns ' \
                  'there. :hide hides everywhere (set the current user in jobs and mailers). The user model stays ' \
                  'readable under both, as sign-in needs.')
        end

        def masked_nil_user_outside_requests
          finding(:info, :masked_nil_user_outside_requests, 'Masked attributes are readable with no current user outside web requests',
                  'masked_attributes_nil_user_strategy is :hide_in_requests: in a web request with nobody signed in ' \
                  'every guarded attribute reads as hidden, but jobs, rake tasks, the runner and the console (and ' \
                  'Action Cable channel actions) read the stored values. That code runs on your servers, not on a ' \
                  'visitor\'s behalf; :hide hides there too, and then needs the current user set in those jobs and mailers.')
        end

        # Middlewares inserted above WebRequest::Middleware read outside the
        # request: :hide_in_requests does not hide there, :bypass does not
        # record (WebRequest::StackCheck, also a boot warning).
        def middleware_above_web_request
          return if configuration.masked_attributes_nil_user_strategy == :hide

          above = PermissionForge::WebRequest::StackCheck.middlewares_above
          return if above.blank?

          finding(:info, :middleware_above_web_request, 'Middlewares run before requests are marked',
                  "#{PermissionForge::WebRequest::StackCheck.message(above, 'are not hidden or recorded')} " \
                  'Middlewares that read no masked model (CORS, profiling, static files) need nothing.', items: above)
        end
      end
    end
  end
end
