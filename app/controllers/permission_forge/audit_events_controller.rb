module PermissionForge
  # The audit log: every recorded event, filtered and paged, one event in
  # full, and the exports (the filtered log as CSV or JSON, and who holds
  # what). Read-only: nothing here writes an event — viewing and exporting
  # are recorded by Audit::AuditedViews, a refusal by AuditLogGate.
  #
  # @api private
  class AuditEventsController < ApplicationController
    include PermissionForge::AuditLogGate

    EXPORT_FORMATS = %w[csv json].freeze
    MAX_KEY_LENGTH = 255

    pf_exports EXPORT_FORMATS.map(&:to_sym), only: %i[index holdings]
    before_action :pf_require_audit_log!

    def index
      @log = PermissionForge::Admin::AuditLog.new(params, include_views: export?)
      return pf_stream(PermissionForge::Admin::Exports::Events.call(@log.relation, filters: @log.filters), 'audit-log') if export?

      @page = @log.page(params[:page])
      @lookups = PermissionForge::Admin::AuditLookups.new(@page.events)
    rescue PermissionForge::Audit::EventQuery::Invalid => e
      invalid_filters(e)
    end

    def show
      @event = find_event || pf_not_found
      @lookups = PermissionForge::Admin::AuditLookups.new([@event])
      @detail = PermissionForge::Admin::AuditEventDetail.new(@event, @lookups)
    end

    # Who holds what: every assignment as it stands, with its review.
    def holdings
      return head(:not_acceptable) unless export?

      pf_stream(PermissionForge::Admin::Exports::Holdings.call, 'who-holds-what')
    end

    private

    def export?
      EXPORT_FORMATS.include?(request.format.symbol.to_s)
    end

    # By uuid (what the pages link to), or by id. A key no column can hold
    # (a NUL byte, longer than a column) is not looked for.
    def find_event
      key = params[:id].to_s
      return nil if key.include?("\0") || key.length > MAX_KEY_LENGTH

      events = PermissionForge::AuditEvent
      events.find_by(uuid: key) || (key.match?(/\A\d{1,18}\z/) ? events.find_by(id: key) : nil)
    end

    def invalid_filters(error)
      return head(:unprocessable_entity) if export?

      @errors = error.errors
      @page = nil
      render :index, status: :unprocessable_entity
    end

    # Hands the file over as it is written (batch by batch), with no cap.
    def pf_stream(document, name)
      format = request.format.symbol.to_s
      headers.merge!(pf_download_headers(format, PermissionForge::Admin::Exports.filename(name, format)))
      self.response_body = pf_in_request_context(document.chunks(format))
    end

    # The body is written after the action's around_actions have ended: the
    # record rules are no longer suspended (the people of the rows would be
    # looked up under the admin's own rules) and the host's tenant may be gone.
    # Each is captured here, in the action, and put back while the body is written.
    def pf_in_request_context(chunks)
      tenant = PermissionForge.ambient_tenant
      Enumerator.new do |out|
        PermissionForge.with_ambient_tenant(tenant) do
          PermissionForge.without_permission_scope { chunks.each { |chunk| out << chunk } }
        end
      end
    end

    # Not buffered or cached on the way: no ETag digest (Last-Modified set),
    # no proxy buffering, nothing stored.
    def pf_download_headers(format, filename)
      {
        'Content-Type' => Mime[format.to_sym].to_s,
        'Content-Disposition' => ActionDispatch::Http::ContentDisposition.format(disposition: 'attachment', filename: filename),
        'Cache-Control' => 'no-store', 'Last-Modified' => Time.current.httpdate, 'X-Accel-Buffering' => 'no'
      }
    end
  end
end
