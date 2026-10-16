# frozen_string_literal: true

require 'test_helper'
require 'rake'
require_relative '../../support/doc_blocks'
require_relative '../../support/rake_tasks'

module PermissionForge
  module Docs
    # The reference lint of README.md and docs/*.md: every relative link and
    # anchor resolves, and so does every link to this repository on GitHub
    # (in the docs and in what the code prints); every `config.<name>`, every
    # `name = value` span and every bare `name` shaped like an option is an
    # option of Configuration; every `permission_forge:<task>` is a defined
    # rake task (or generator), and every defined task is documented with the
    # environment variables it reads (ACTOR and REASON through RakeAudit
    # included); every `PermissionForge::…` constant resolves; a default a
    # sentence states for an option is the default of Configuration.new.
    # Fixtures at the end prove each rule bites.
    class ReferencesTest < ActiveSupport::TestCase
      ROOT = DocBlocks::ROOT
      DOCS = DocBlocks.files.freeze
      # Links are also checked in the files that link into docs/.
      LINKED = (DOCS + %w[CHANGELOG.md CONTRIBUTING.md RELEASING.md SECURITY.md]).freeze
      TASK_FILES = Dir[ROOT.join('lib/tasks/*.rake').to_s].freeze
      GENERATORS = Dir[ROOT.join('lib/generators/permission_forge/*/').to_s].map { |path| File.basename(path) }.freeze

      # Rails' own `config.*` the docs show next to PermissionForge's; a stale entry fails.
      RAILS_CONFIG = {
        'action_dispatch' => 'config.action_dispatch.rescue_responses, a Rails setting',
        'active_support' => 'config.active_support.*, Rails settings',
        'after_initialize' => 'config.after_initialize, a Rails hook',
        'api_only' => 'config.api_only, a Rails setting (rails new --api)',
        'cache_store' => 'config.cache_store in config/environments, a Rails setting',
        'filter_parameters' => 'Rails.application.config.filter_parameters',
        'load_defaults' => 'config.load_defaults, Rails',
        'middleware' => 'config.middleware.use, the Rails middleware stack',
        'rake_eager_load' => 'config.rake_eager_load, Rails',
        'to_prepare' => 'config.to_prepare, a Rails hook'
      }.freeze

      # Inline code shaped like an option that names something else: `name = value` spans, and bare `name`s that
      # share an option's first two words or are within two edits of one. A stale entry fails.
      NOT_OPTIONS = {
        'owner_id' => 'a rule in prose (`owner_id = current_user.id`)',
        'permitted' => 'a local in a Rails 7 scaffold line',
        'require_tenant' => "acts_as_tenant's setting",
        'consider_all_requests_local' => 'a Rails setting',
        'is_editable' => 'a column of the permission models',
        'audit_event' => 'an api_serializer_overrides key',
        'extra_fields_for_permissions' => "extra_fields_method's default method name",
        'api_auth_denied' => 'an api.auth_failed reason', 'api_auth_not_configured' => 'an api.auth_failed reason',
        'audit_log_not_authorized' => 'an auth_failed reason',
        'conditional_sets_lenient' => 'a SecurityAudit finding', 'audit_hook_failures_logged' => 'a SecurityAudit finding',
        'gdpr_defaults_off' => 'a SecurityAudit finding', 'audit_trail_off' => 'a SecurityAudit finding',
        'nil_user_bypass' => 'a SecurityAudit finding', 'action_guard_missing' => 'a SecurityAudit finding',
        'audit_runtime_default' => 'a SecurityAudit finding'
      }.freeze
      ASSIGNED_SPAN = /`((\w+) = [^`]+)`/
      BARE_SPAN = /`(\w+)`/

      # Constants the docs name that are not defined in the gem; a stale entry fails.
      CONSTANTS_ALLOWED = {
        'PermissionForge::Cache::RedisCache' => 'migration-guide.md names it as removed'
      }.freeze

      # A link to this repository on GitHub names a file of it: the repository's page (README.md) or a file on main.
      REPOSITORY_URL = %r{\Ahttps://github\.com/fetijashari/permission_forge(?:/(?:blob|tree)/main/(?<path>[^#?]*))?/?(?:#(?<fragment>.*))?\z}
      # Where the code prints such a link (the install generator's Quick Start, the initializer template, the admin).
      CODE_WITH_LINKS = %w[lib/**/*.rb lib/**/*.tt app/**/*.rb app/**/*.erb].freeze

      CONSTANT = /\b(PermissionForge(?:::[A-Z]\w*)+)/
      # `config.<name>` as the docs write PermissionForge's options; `Foo.config.adapter` is somebody else's config.
      CONFIG_NAME = /(?<![\w.])config\.(\w+)/
      LITERAL = /:[a-z_]+|true|false|nil|-?\d+/
      # A default stated in prose: "`option` ... (default `:x`)", "default `:x`" after the option's name on the
      # line, "default `option = :x`", or a config line whose comment says it is the default.
      INLINE_DEFAULT = /\bdefaults?(?: is| to|:)? `(#{LITERAL})`|\(default:? `?(#{LITERAL})`?\)/
      ASSIGNED_DEFAULT = /`(\w+) = (#{LITERAL})`/
      CONFIG_LINE = /\A\s*config\.(\w+)\s*=\s*(#{LITERAL})\s*#(.*)\z/

      # The gem's rake tasks, loaded once into an application of their own.
      def self.rake_application
        @rake_application ||= begin
          previous = Rake.application
          app = Rake.application = Rake::Application.new
          Rake::Task.define_task(:environment)
          TASK_FILES.each { |file| load file }
          Rake.application = previous
          app
        end
      end

      def read(file) = File.read(ROOT.join(file))

      # ---- links --------------------------------------------------------------------

      test 'every relative link and anchor in the docs resolves' do
        problems = LINKED.flat_map { |file| link_problems(file, read(file)) }
        assert_empty problems, problems.join("\n")
      end

      test 'every link to this repository the code prints names a file and anchor of it' do
        found = CODE_WITH_LINKS.flat_map { |glob| Dir[ROOT.join(glob).to_s] }.flat_map do |path|
          File.read(path).scan(%r{https://github\.com/fetijashari/permission_forge[^\s'"`)<>]*}).map do |url|
            [path.delete_prefix("#{ROOT}/"), url.sub(/[.,;:]+\z/, '')] # a full stop after the link ends the sentence
          end
        end
        problems = found.filter_map { |file, url| (problem = repository_link_problem(url)) && "#{file}: #{problem}" }
        assert_empty problems, problems.join("\n")
        assert_includes found.map(&:last), 'https://github.com/fetijashari/permission_forge#quick-start', 'the generator prints the Quick Start link'
      end

      # ---- config.* -----------------------------------------------------------------

      test 'every config.<name> the docs name is an option of Configuration' do
        problems = DOCS.flat_map { |file| config_name_problems(file, read(file)) }
        assert_empty problems, problems.join("\n")
        named = DOCS.flat_map { |file| read(file).scan(CONFIG_NAME).flatten }.uniq
        stale = RAILS_CONFIG.keys - named
        assert_empty stale, "RAILS_CONFIG entries no doc names any more: #{stale.inspect}"
      end

      test 'every option the docs write as `name = value`, or as a bare `name` shaped like an option, is one' do
        problems = DOCS.flat_map { |file| option_span_problems(file, read(file)) }
        assert_empty problems, problems.join("\n")
        named = DOCS.flat_map { |file| read(file).scan(/`(\w+)(?: = [^`]+)?`/).flatten }.uniq
        stale = NOT_OPTIONS.keys - named
        assert_empty stale, "NOT_OPTIONS entries no doc names any more: #{stale.inspect}"
      end

      # ---- rake tasks -----------------------------------------------------------------

      test 'every permission_forge:<task> the docs name is a defined rake task or generator' do
        problems = DOCS.flat_map { |file| task_name_problems(file, read(file)) }
        assert_empty problems, problems.join("\n")
      end

      test 'every defined rake task is documented, with the environment variables it reads' do
        problems = task_names.flat_map { |name| task_documentation_problems(name) }
        assert_empty problems, problems.join("\n")
      end

      # ---- constants ------------------------------------------------------------------

      test 'every PermissionForge constant the docs name resolves' do
        problems = DOCS.flat_map { |file| constant_problems(file, read(file)) }
        assert_empty problems, problems.join("\n")
        named = DOCS.flat_map { |file| read(file).scan(CONSTANT).flatten }.uniq
        stale = CONSTANTS_ALLOWED.keys - named
        assert_empty stale, "CONSTANTS_ALLOWED entries no doc names any more: #{stale.inspect}"
      end

      # ---- defaults -------------------------------------------------------------------

      test 'every default a sentence states for an option is the default of Configuration.new' do
        problems = DOCS.flat_map { |file| default_problems(file, read(file)) }
        assert_empty problems, problems.join("\n")
        assert_operator claims_checked.size, :>=, 15, "the default lint should recognise the docs' own phrasing"
      end

      # ---- the guard bites ------------------------------------------------------------

      test 'a missing file, a missing anchor and a link into a code block are reported' do
        assert_equal ['fixture.md:1: missing file nope.md'], link_problems('fixture.md', '[x](nope.md)')
        assert_equal ['docs/fixture.md:3: missing anchor #no-such (in docs/fixture.md)'],
                     link_problems('docs/fixture.md', "## Real Heading\n\n[x](#no-such)")
        assert_empty link_problems('docs/fixture.md', "## Real Heading (`x`)\n\n[x](#real-heading-x) [y](../README.md#installation)")
        assert_equal ['docs/fixture.md:5: missing anchor #inside (in docs/fixture.md)'],
                     link_problems('docs/fixture.md', "```ruby fragment\n# inside\n```\n\n[x](#inside)")
        assert_empty link_problems('docs/fixture.md', "## Twice\n## Twice\n\n[x](#twice-1)")
      end

      test 'a link to this repository on GitHub is checked as the file it names' do
        assert_equal ['docs/fixture.md:1: missing anchor #no-such (in docs/audit-log.md)'],
                     link_problems('docs/fixture.md', '[x](https://github.com/fetijashari/permission_forge/blob/main/docs/audit-log.md#no-such)')
        assert_equal ['docs/fixture.md:1: missing file https://github.com/fetijashari/permission_forge/blob/main/docs/nope.md'],
                     link_problems('docs/fixture.md', '[x](https://github.com/fetijashari/permission_forge/blob/main/docs/nope.md)')
        repository = 'https://github.com/fetijashari/permission_forge'
        assert_empty link_problems('docs/fixture.md', "[x](#{repository}/blob/main/docs/audit-log.md#retention-and-purge) " \
                                                      "[y](#{repository}/actions/workflows/ci.yml) [z](https://example.com/#x)")
        assert_equal 'missing anchor #no-such-section (in README.md)', repository_link_problem('https://github.com/fetijashari/permission_forge#no-such-section')
        assert_nil repository_link_problem('https://github.com/fetijashari/permission_forge#quick-start')
      end

      test 'an unknown config name, task and constant are reported' do
        assert_equal ['fixture.md:1: config.no_such_option is not a Configuration option'],
                     config_name_problems('fixture.md', 'set `config.no_such_option = true`')
        assert_empty config_name_problems('fixture.md', '`config.nil_user_strategy` and `config.action_dispatch.rescue_responses`')
        assert_equal ['fixture.md:1: permission_forge:no_such_task is not a rake task or generator'],
                     task_name_problems('fixture.md', 'run `bin/rails permission_forge:no_such_task`')
        assert_empty task_name_problems('fixture.md', '`permission_forge:audit`, `permission_forge:rls:sync`, `permission_forge:install`')
        assert_equal ['fixture.md:1: PermissionForge::Services::NoSuchService does not resolve'],
                     constant_problems('fixture.md', 'call `PermissionForge::Services::NoSuchService.call`')
        assert_empty constant_problems('fixture.md', '`PermissionForge::Services::MaskValue.call`')
      end

      test 'an option renamed in the docs, written as `name = value` or as a bare name, is reported' do
        assert_equal ['fixture.md:1: `no_such_option = true` names no Configuration option'],
                     option_span_problems('fixture.md', 'set `no_such_option = true`')
        assert_equal ['fixture.md:1: `auto_query_scopin = :off` names no Configuration option'],
                     option_span_problems('fixture.md', 'With the default `auto_query_scopin = :off` nothing changes')
        assert_equal ['fixture.md:1: `nil_user_strategies` looks like an option (nil_user_strategy) but is not one'],
                     option_span_problems('fixture.md', '`nil_user_strategies` (default `:bypass`) decides')
        assert_equal ['fixture.md:1: `cache_tll` looks like an option (cache_ttl) but is not one'],
                     option_span_problems('fixture.md', 'lower `cache_tll`')
        assert_empty option_span_problems('fixture.md', '`nil_user_strategy`, `nil_user_strategy = :deny`, `read_access`, `owner_id = 1`, ' \
                                                        '`mask_strategy` and `user_ids`')
      end

      test 'a task without a doc, or documented without an env var it reads, is reported' do
        problems = task_documentation_problems('permission_forge:erasure', docs_text: { 'docs/x.md' => '`permission_forge:erasure`' })
        assert_equal ['permission_forge:erasure: no doc that names it mentions ACTOR, DRY_RUN, REASON, USER_ID ' \
                      '(lib/tasks/permission_forge_gdpr.rake reads them)'], problems
        assert_equal ['permission_forge:erasure: no doc names it'], task_documentation_problems('permission_forge:erasure', docs_text: {})
        # ACTOR and REASON are read by RakeAudit, not in the task body: a doc without them is still reported.
        assert_equal ['permission_forge:erasure: no doc that names it mentions ACTOR, REASON (lib/tasks/permission_forge_gdpr.rake reads them)'],
                     task_documentation_problems('permission_forge:erasure',
                                                 docs_text: { 'docs/x.md' => 'USER_ID=1 DRY_RUN=false bin/rails permission_forge:erasure' })
        documented = 'ACTOR=me REASON=t USER_ID=1 DRY_RUN=false bin/rails permission_forge:erasure'
        assert_empty task_documentation_problems('permission_forge:erasure', docs_text: { 'docs/x.md' => documented })
      end

      test 'a wrong default is reported in each phrasing, an unknown option or value is not asserted' do
        assert_equal ['fixture.md:1: `nil_user_strategy` default stated as `:deny`, Configuration.new has `:bypass`'],
                     default_problems('fixture.md', '`nil_user_strategy` (default `:deny`) decides')
        assert_equal ['fixture.md:1: `auto_query_scoping` default stated as `:filter_only`, Configuration.new has `:off`'],
                     default_problems('fixture.md', 'With the default `auto_query_scoping = :filter_only` nothing changes')
        assert_equal ['fixture.md:1: `cache_ttl` default stated as `1800`, Configuration.new has `3600`'],
                     default_problems('fixture.md', '  config.cache_ttl = 1800   # default')
        assert_equal ['fixture.md:1: `conditional_sets_strict_mode` default stated as `true`, Configuration.new has `false`'],
                     default_problems('fixture.md', '  config.conditional_sets_strict_mode = true   # default: true')
        assert_empty default_problems('fixture.md', '  config.conditional_sets_strict_mode = true   # default: false')
        assert_empty default_problems('fixture.md',
                                      '`nil_user_strategy` (default `:bypass`); `something_else` (default `:deny`); defaults to `Time.current`')
      end

      private

      # ---- links --------------------------------------------------------------------

      def link_problems(file, text)
        texts[file] = text
        anchors.delete(file)
        problems = []
        outside_fences(text) do |line, number|
          line.scan(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten.each do |target|
            problem = target.match?(/\A(?:https?:|mailto:)/) ? repository_link_problem(target) : link_problem(file, target)
            problems << "#{file}:#{number}: #{problem}" if problem
          end
        end
        problems
      end

      def link_problem(file, target)
        path, fragment = target.split('#', 2)
        resolved = resolve(file, path)
        return "missing file #{target}" unless path.to_s.empty? || File.exist?(ROOT.join(resolved))
        return nil if fragment.nil? || !resolved.end_with?('.md')

        "missing anchor ##{fragment} (in #{resolved})" unless anchors_of(resolved).include?(fragment)
      end

      # A link to this repository on GitHub (REPOSITORY_URL), checked as the repository file it names; any other
      # URL is not checked (nil). The repository's own page is its README.md.
      def repository_link_problem(url)
        match = url.match(REPOSITORY_URL) or return
        path = match[:path].presence || 'README.md'
        problem = link_problem('README.md', [path, match[:fragment]].compact.join('#')) # README.md: a path from the root
        problem&.sub(/\Amissing file .*/, "missing file #{url}")
      end

      # The repository path a link's path names from `file` (the file itself for a bare #anchor).
      def resolve(file, path)
        return file if path.to_s.empty?

        File.expand_path(path, File.dirname(ROOT.join(file))).delete_prefix("#{ROOT}/")
      end

      # The text of a file: what link_problems was given (a fixture), else the file.
      def texts = @texts ||= {}

      def anchors = @anchors ||= {}

      # GitHub's heading slugs (headings inside a code fence do not count) plus explicit <a id>/<a name> anchors.
      def anchors_of(file)
        anchors[file] ||= slugs(texts[file] || read(file))
      end

      def slugs(text)
        counts = Hash.new(0)
        anchors = text.scan(/<a (?:id|name)="([^"]+)"/).flatten
        outside_fences(text) do |line, _number|
          next unless line.match?(DocBlocks::HEADING)

          slug = line.sub(/\A#+\s*/, '').strip.downcase.gsub(/[^\p{Word}\- ]/, '').tr(' ', '-')
          seen = counts[slug]
          counts[slug] += 1
          anchors << (seen.zero? ? slug : "#{slug}-#{seen}")
        end
        anchors
      end

      # Yields each line outside a fenced code block with its 1-based number.
      def outside_fences(text)
        open = nil
        text.lines.each_with_index do |raw, index|
          line = raw.chomp
          if open
            open = nil if DocBlocks.closes?(line, open)
          elsif (match = line.match(DocBlocks::FENCE))
            open = { fence: match[:fence] }
          else
            yield line, index + 1
          end
        end
      end

      # ---- config.* -----------------------------------------------------------------

      def options
        @options ||= (Configuration.public_instance_methods - Object.public_instance_methods).to_set { |name| name.to_s.chomp('=') }
      end

      def config_name_problems(file, text)
        each_line_match(file, text, CONFIG_NAME) do |name|
          "config.#{name} is not a Configuration option" unless options.include?(name) || RAILS_CONFIG.key?(name)
        end
      end

      # `name = value` must assign an option; a bare `name` that looks like one must be one (or a method of
      # Configuration). NOT_OPTIONS names the exceptions.
      def option_span_problems(file, text)
        text.lines.each_with_index.flat_map do |line, index|
          (assigned_span_problems(line) + bare_span_problems(line)).map { |problem| "#{file}:#{index + 1}: #{problem}" }
        end.uniq
      end

      def assigned_span_problems(line)
        line.scan(ASSIGNED_SPAN).filter_map do |span, name|
          "`#{span}` names no Configuration option" unless option?(name) || NOT_OPTIONS.key?(name) || RAILS_CONFIG.key?(name)
        end
      end

      def bare_span_problems(line)
        line.scan(BARE_SPAN).flatten.filter_map do |name|
          next if options.include?(name) || NOT_OPTIONS.key?(name)

          (like = option_like(name)) && "`#{name}` looks like an option (#{like}) but is not one"
        end
      end

      # The writer option a name resembles: the same first two words (of three or more), or within two edits.
      def option_like(name)
        words = name.split('_')
        prefix = "#{words.first(2).join('_')}_" if words.size > 2
        writers.find { |option| (prefix && option.start_with?(prefix)) || DidYouMean::Levenshtein.distance(option, name) <= 2 }
      end

      def writers = @writers ||= options.select { |name| option?(name) }.sort

      def each_line_match(file, text, pattern)
        text.lines.each_with_index.flat_map do |line, index|
          line.scan(pattern).flatten.filter_map do |capture|
            problem = yield capture
            "#{file}:#{index + 1}: #{problem}" if problem
          end
        end.uniq
      end

      # ---- rake tasks -----------------------------------------------------------------

      def task_names = self.class.rake_application.tasks.map(&:name).grep(/\Apermission_forge:/)

      def task_name_problems(file, text)
        each_line_match(file, text, /\bpermission_forge:([a-z_]+(?::[a-z_]+)*)/) do |name|
          next if task_names.include?("permission_forge:#{name}") || GENERATORS.include?(name)

          "permission_forge:#{name} is not a rake task or generator"
        end
      end

      def task_documentation_problems(name, docs_text: DOCS.to_h { |file| [file, read(file)] })
        naming = docs_text.select { |_file, text| text.include?(name) }
        return ["#{name}: no doc names it"] if naming.empty?

        file, env = env_reads.fetch(name.split(':').last)
        missing = env.reject { |var| naming.values.any? { |text| text.include?(var) } }
        return [] if missing.empty?

        ["#{name}: no doc that names it mentions #{missing.join(', ')} (#{file} reads them)"]
      end

      # The environment variables each task body reads (RakeTasks.env_keys_read: literally, and ACTOR / REASON
      # through RakeAudit), by the task's short name.
      def env_reads
        @env_reads ||= TASK_FILES.each_with_object({}) do |path, reads|
          file = path.delete_prefix("#{ROOT}/")
          File.read(path).split(/^(?=\s*task \w+)/).each do |chunk|
            short = chunk[/\A\s*task (\w+)/, 1] or next
            reads[short] = [file, RakeTasks.env_keys_read(chunk)]
          end
        end
      end

      # ---- constants ------------------------------------------------------------------

      def constant_problems(file, text)
        each_line_match(file, text, CONSTANT) do |name|
          next if CONSTANTS_ALLOWED.key?(name)

          Object.const_get(name)
          nil
        rescue NameError
          "#{name} does not resolve"
        end
      end

      # ---- defaults -------------------------------------------------------------------

      def claims_checked = @claims_checked ||= []

      def default_problems(file, text)
        text.lines.each_with_index.filter_map do |line, index|
          option, claimed = default_claim(line)
          next unless option

          claims_checked << [file, index + 1, option, claimed]
          actual = Configuration.new.public_send(option)
          next if literal_equal?(claimed, actual)

          "#{file}:#{index + 1}: `#{option}` default stated as `#{claimed}`, Configuration.new has `#{actual.inspect}`"
        end
      end

      # [option, literal] when the line states a default confidently, else nil.
      def default_claim(line)
        config_line_claim(line) || assigned_claim(line) || inline_claim(line)
      end

      # `config.cache_ttl = 3600 # ... default` claims the assigned value; `# default: 300` in the comment claims 300.
      def config_line_claim(line)
        match = line.match(CONFIG_LINE) or return
        option, assigned, comment = match.captures
        return unless option?(option) && comment.match?(/\bdefault\b/)

        [option, comment[/\bdefault:?\s+`?(#{LITERAL})`?/, 1] || assigned]
      end

      # "the default `auto_query_scoping = :off`"
      def assigned_claim(line)
        match = line.match(/\bdefault(?:s)?(?: is| to|:)? #{ASSIGNED_DEFAULT}/) or return
        match.captures if option?(match[1])
      end

      # "`nil_user_strategy` (default `:bypass`)": the option is the nearest `code span` before the phrase that
      # starts with an option name (`nil_user_strategy`, `admin_tenantless_access = :allow`); a literal of another
      # kind than the option's default names some other setting and is not asserted.
      def inline_claim(line)
        match = line.match(INLINE_DEFAULT) or return
        claimed = match[1] || match[2]
        option = line[0...match.begin(0)].scan(/`(\w+)[^`]*`/).flatten.reverse.find { |name| option?(name) }
        [option, claimed] if option && same_kind?(claimed, Configuration.new.public_send(option)) && value_of?(option, claimed)
      end

      def option?(name) = Configuration.public_method_defined?(:"#{name}=")

      # A Symbol stated for an option with a known value list (StrategyValues, the Settings catalog) that is
      # not one of its values names another option's default ("`audit_events = true` under the default `:raise`").
      def value_of?(option, claimed)
        return true unless claimed.start_with?(':')

        values = Configuration::StrategyValues::ALLOWED[option.to_sym] || Admin::SettingsCatalog::DEFINITIONS.find { |d| d.key == option }&.options
        values.nil? || values.map(&:to_s).include?(claimed.delete_prefix(':'))
      end

      def same_kind?(claimed, actual)
        case claimed
        when /\A:/ then actual.is_a?(Symbol)
        when 'true', 'false' then [true, false].include?(actual)
        when 'nil' then true
        else actual.is_a?(Integer)
        end
      end

      def literal_equal?(claimed, actual)
        case claimed
        when /\A:/ then actual == claimed.delete_prefix(':').to_sym
        when 'true' then actual == true
        when 'false' then actual == false
        when 'nil' then actual.nil?
        else actual == Integer(claimed)
        end
      end
    end
  end
end
