module PermissionForge
  # Serves the admin UI's own stylesheet, script and brand files straight from
  # the gem, so the engine works without Sprockets, Propshaft, importmap or any
  # other host asset pipeline.
  #
  # Inherits from ActionController::Base on purpose — never from the host's
  # base_controller_class — so host before_actions (sign-in redirects, tenant
  # lookups, layouts) can't break or leak into static files. Nothing served
  # here is sensitive: it is the same CSS/JS/logo for every visitor.
  #
  # @api private
  class AssetsController < ActionController::Base
    ROOT = Engine.root.join('app', 'frontend', 'permission_forge').freeze

    # Allow-list: published name => [relative path, content type].
    FILES = {
      'pf_admin.css' => ['pf_admin.css', 'text/css'],
      'pf_admin.js' => ['pf_admin.js', 'text/javascript'],
      'logo-light.svg' => ['brand/logo-horizontal-light.svg', 'image/svg+xml'],
      'logo-dark.svg' => ['brand/logo-horizontal-dark.svg', 'image/svg+xml'],
      'mark.svg' => ['brand/mark.svg', 'image/svg+xml'],
      'mark-small.svg' => ['brand/mark-small.svg', 'image/svg+xml'],
      'favicon.svg' => ['brand/favicon.svg', 'image/svg+xml'],
      'favicon.ico' => ['brand/favicon.ico', 'image/x-icon'],
      'apple-touch-icon.png' => ['brand/apple-touch-icon.png', 'image/png'],
      'chevron.svg' => ['brand/chevron.svg', 'image/svg+xml']
    }.freeze

    # GET-only; CSRF protection stays on (no-op for GET) so no request path
    # ever runs unprotected. The cross-origin <script> check is skipped: this
    # controller exists to serve pf_admin.js to <script src> tags, and the
    # file is the same public, static script for every visitor.
    include PermissionForge::ForgeryProtection

    pf_protect_from_forgery with: :exception
    skip_after_action :verify_same_origin_request

    def show
      name = params[:file].to_s
      path, type = asset_entry(name)
      return head(:not_found) unless path

      cache_headers(name)
      return unless stale?(etag: self.class.digest(name), public: true)

      response.headers['X-Content-Type-Options'] = 'nosniff'
      send_file path, type: type, disposition: 'inline'
    end

    private

    # [absolute path, content type] for an allow-listed name whose file exists, else nil.
    def asset_entry(name)
      path, type = self.class.entries[name]
      [path, type] if path && File.file?(path)
    end

    # Fingerprinted URLs (?v=digest) never change content, so they can be
    # cached forever; unversioned requests revalidate via ETag.
    def cache_headers(name)
      version = params[:v]
      if version.present? && version == self.class.digest(name)
        response.headers['Cache-Control'] = 'public, max-age=31536000, immutable'
      else
        expires_in 0, public: true, must_revalidate: true
      end
    end

    class << self
      # Allow-list resolved to absolute paths: name => [path, content type].
      # Paths come only from FILES, never from the request.
      def entries
        @entries ||= FILES.to_h { |name, (relative, type)| [name, [ROOT.join(relative).to_s, type]] }.freeze
      end

      # Short content digest used as the cache-busting `v` query param.
      def digest(name)
        @digests ||= {}
        return @digests[name] if @digests.key?(name) && !reload_assets?

        entry = FILES[name.to_s]
        @digests[name] = entry ? Digest::SHA256.file(ROOT.join(entry.first)).hexdigest[0, 12] : nil
      end

      private

      # Recompute digests on every request in development so CSS/JS edits in
      # the gem show up without a server restart.
      def reload_assets?
        defined?(Rails) && Rails.env.development?
      end
    end
  end
end
