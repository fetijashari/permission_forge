# frozen_string_literal: true

module PermissionForge
  module Security
    # The request parameters the engine reads, found in its source so that a
    # parameter added later is fuzzed without anybody listing it (R2 review,
    # P1-1): RouteFuzzTest poisons, per route, each parameter its controller
    # reads, one at a time, the rest of the request valid; its guard test
    # fails when a parameter read anywhere is missing from the fuzz table.
    #
    # A read is `params[:x]`, `params['x']`, `@params[:x]` (a form object
    # handed the params), `params.require/fetch/key?/dig(:x)`, a ParamShapes
    # reader (`pf_text_param(:x)`, `pf_require_hash(:x)` …) and, inside an
    # attribute section, every key of the `.permit(...)` that follows it —
    # or, in the API, every key `pf_record_attributes(:x, Model, :a, :b)`
    # names (Api::InputShapes reads the section without `.permit`).
    module FuzzParams
      ROOT = File.expand_path('../../..', __dir__)

      TOP_LEVEL = [
        /(?:\bcontroller\.|@|\b)params\[:(\w+)\]/,
        /(?:\bcontroller\.|@|\b)params\[['"](\w+)['"]\]/,
        /\bparams\.(?:require|fetch|key\?|dig)\(:(\w+)/,
        /\bpf_(?:text|integer|boolean|time)_param\(:(\w+)/,
        /\bpf_(?:require_hash|hash_param|id_list)\(:(\w+)/,
        /\bpf_record_attributes\(\s*:(\w+)/
      ].freeze
      TAB_READER = /\bpf_tab_param\(/
      SECTION = /\bpf_(?:require_hash|hash_param)\(:(\w+)\)/
      PERMIT = /\.permit\(([^)]*)\)/m
      # The API's attribute sections: the section, the model, the keys.
      RECORD_ATTRIBUTES = /\bpf_record_attributes\(\s*:(\w+)\s*,\s*[\w:]+\s*,([^)]*)\)/m

      # Read for every request: the audit context (`reason`) and the audited
      # pages (Audit::AuditedViews).
      REQUEST_FILES = %w[lib/permission_forge/audit/request_context.rb lib/permission_forge/audit/audited_views.rb].freeze
      # Controllers that hand the params (or a part of them) to a reader
      # outside app/controllers, and the parameters that reader takes.
      INDIRECT_FILES = {
        'permission_forge/permission_sets' => %w[lib/permission_forge/admin/conditions_form.rb]
      }.freeze
      # The audit log's filters, read by Audit::EventQuery from the params it
      # is given (the log page and the API pass them all).
      LOG_CONTROLLERS = %w[permission_forge/audit_events permission_forge/api/audit_events].freeze

      def self.indirect_params(controller)
        LOG_CONTROLLERS.include?(controller) ? PermissionForge::Admin::AuditLog::FILTERS : []
      end

      # Every file whose code reads request parameters.
      def self.all_files
        glob('app/controllers/**/*.rb', 'app/views/**/*.erb', 'app/helpers/**/*.rb', 'lib/permission_forge/admin/**/*.rb',
             'lib/permission_forge/audit/event_query.rb', *REQUEST_FILES)
      end

      # Parameter names read anywhere, with the files reading each.
      #
      # @return [Hash{String => Array<String>}]
      def self.all_reads
        reads = Hash.new { |hash, key| hash[key] = [] }
        all_files.each { |file| top_level_in(File.read(file)).each { |name| reads[name] << relative(file) } }
        PermissionForge::Admin::AuditLog::FILTERS.each { |name| reads[name] << 'admin/audit_log.rb FILTERS' }
        reads
      end

      # The parameters `controller` reads: its own file, the modules it
      # includes, its base controller, its views, the shared views and the
      # helpers, and the readers it hands the params to.
      #
      # @return [Array<String>]
      def self.read_by(controller)
        files = files_for(controller)
        (files.flat_map { |file| top_level_in(File.read(file)) } + indirect_params(controller)).uniq.sort
      end

      # Attribute sections (`pf_require_hash(:rule)`) to the keys permitted in
      # them, across the controllers.
      #
      # @return [Hash{String => Array<String>}]
      def self.sections
        glob('app/controllers/**/*.rb').each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |file, sections|
          section_permits(File.read(file)).each { |section, keys| sections[section] |= keys }
        end
      end

      def self.files_for(controller)
        base = if controller.start_with?('permission_forge/api/')
                 'app/controllers/permission_forge/api/base_controller.rb'
               else
                 'app/controllers/permission_forge/application_controller.rb'
               end
        ruby = with_included(["app/controllers/#{controller}_controller.rb", base].map { |path| File.join(ROOT, path) }) +
               REQUEST_FILES.map { |path| File.join(ROOT, path) }
        ruby + glob("app/views/#{controller}/**/*.erb", 'app/views/permission_forge/shared/**/*.erb',
                    'app/views/layouts/permission_forge/**/*.erb', 'app/helpers/**/*.rb') +
          INDIRECT_FILES.fetch(controller, []).map { |path| File.join(ROOT, path) }
      end

      # Comment lines name parameters in examples; they read nothing.
      def self.top_level_in(source)
        source = source.gsub(/^\s*#.*$/, '').gsub(/<%#.*?%>/m, '')
        names = TOP_LEVEL.flat_map { |pattern| source.scan(pattern).flatten }
        names << 'tab' if source.match?(TAB_READER)
        names.uniq
      end

      # Each `.permit(...)` is the section read last before it in the file;
      # each `pf_record_attributes(:section, Model, :key, ...)` names its own.
      def self.section_permits(source)
        source = source.gsub(/^\s*#.*$/, '')
        permits = source.to_enum(:scan, PERMIT).filter_map do
          match = Regexp.last_match
          section = source[0, match.begin(0)].scan(SECTION).flatten.last
          [section, keys_in(match[1])] if section
        end
        permits + record_attribute_sections(source)
      end

      # [section, keys] of each `pf_record_attributes(:section, Model, :key, ..., record: x)`.
      def self.record_attribute_sections(source)
        source.scan(RECORD_ATTRIBUTES).map { |section, keys| [section, keys.scan(/:(\w+)/).flatten.uniq] }
      end

      def self.keys_in(list)
        list.scan(/:(\w+)|(\w+):/).flatten.compact.uniq
      end

      def self.with_included(files)
        found = files.dup
        files.each do |file|
          File.read(file).scan(/^\s*include\s+(?:PermissionForge::)?(?:Api::)?(\w+)\s*$/).flatten.each do |name|
            path = glob("app/controllers/**/#{name.underscore}.rb").first
            found.concat(with_included([path])) if path && found.exclude?(path)
          end
        end
        found.uniq
      end

      def self.glob(*patterns)
        patterns.flat_map { |pattern| Dir[File.join(ROOT, pattern)] }.sort
      end

      def self.relative(file)
        file.delete_prefix("#{ROOT}/")
      end
    end
  end
end
