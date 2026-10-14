# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module AuditIntegration
    # The audit events of the permission models come from their create,
    # update and destroy callbacks. A write that skips callbacks writes no
    # event — the log would silently miss a change. This test scans the
    # gem's own code (lib/ and app/: .rb, .rake, .tt, .erb) for every way of
    # writing past the callbacks and fails on one that is not in ALLOWLIST
    # with a reason.
    #
    # What counts as a hit (comments are stripped first; a method DEFINITION
    # is never a hit). Names count as calls, symbols (`each(&:delete)`,
    # `in_batches(&:delete_all)`) and dynamic sends (`public_send(:update_columns, …)`,
    # `send('delete')`) alike:
    # - always: update_all, delete_all, insert_all(!), upsert_all, upsert,
    #   update_column(s), update_counters, increment_counter,
    #   decrement_counter, touch_all, delete_by, exec_delete, exec_update,
    #   exec_insert, touch (also `touch: true` on an association; not
    #   `touch: false`), increment!, decrement!, toggle!;
    # - `dependent: :delete_all | :delete | :nullify`;
    # - `delete` the way ActiveRecord uses it: with no argument
    #   (`record.delete`, `record.delete if x`), as a block symbol (`&:delete`)
    #   or a sent name (`send(:delete)`) — not a bare `:delete` (HTTP method,
    #   CRUD key) —, on a constant (`Model.delete(id)`), on a call chain
    #   (`where(...).delete(id)`, `Model.unscoped.delete(ids)`,
    #   `Model.all.delete(ids)`, `record.class.delete(id)`) or opening a
    #   continuation line (`  .delete(ids)`) — unless its argument is a
    #   string literal (String#delete, ENV.delete('X')). Not hits, to keep
    #   false positives out: `hash.delete(key)` / `cache.delete(key)` /
    #   `ENV.delete(var)` with an argument on a variable or ENV, `params.delete :x`,
    #   `hash.delete key` — so `klass.delete(id)` through a variable holding a
    #   model goes unseen;
    # - `insert(!)` on a constant (`Model.insert(...)`);
    # - the has_many collections of the permission models emptied or
    #   replaced (`set.resources.delete(r)`, `.clear`, `group.permission_sets = [...]`,
    #   `_ids =`): they delete or nullify without callbacks;
    # - raw SQL, searched in the whole file (comments out, strings in), in
    #   any case and across lines (heredocs): DELETE FROM, INSERT INTO,
    #   UPDATE <table> SET <column> =, TRUNCATE TABLE / TRUNCATE <name>, and
    #   `connection.truncate(...)` / `truncate_tables`. ActiveSupport's
    #   String#truncate (`name.truncate(40)`) is not a hit.
    class CallbackBypassGuardTest < ActiveSupport::TestCase
      ROOT = PermissionForge::Engine.root
      GLOBS = %w[lib/**/*.rb lib/**/*.rake lib/**/*.tt app/**/*.rb app/**/*.erb].freeze

      COLLECTIONS = %w[permission_set_users permission_set_group_users permission_sets resources resource_fields resource_actions
                       permission_set_rules].freeze
      COLLECTION_IDS = %w[permission_set_user permission_set_group_user permission_set resource resource_field resource_action
                          permission_set_rule].freeze
      NOT_A_DEFINITION = '(?<!def[ ])(?<!def[ ]self\.)'
      # A name as a call or a symbol, never a constant path's tail (Foo::touch).
      NAME_START = '(?<!::)(?<![\w-])'
      CALLBACK_SKIPPING = %w[update_all delete_all insert_all! insert_all upsert_all upsert update_columns update_column update_counters
                             increment_counter decrement_counter touch_all delete_by exec_delete exec_update exec_insert].freeze
      DYNAMIC = (CALLBACK_SKIPPING + %w[delete touch increment! decrement! toggle!]).map { |name| Regexp.escape(name) }.join('|')
      STRING_LITERAL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/
      KEYWORD = '(?:if|unless|and|or|rescue|then|end|while|until)\b'

      # Line rules, matched in the code with its string literals blanked.
      RULES = {
        bulk_write: /#{NAME_START}#{NOT_A_DEFINITION}(?:#{CALLBACK_SKIPPING.map { |name| Regexp.escape(name) }.join('|')})(?![\w?=:])/,
        touch: /#{NAME_START}#{NOT_A_DEFINITION}touch\b(?![?=-])(?!:\s*false\b)/,
        counter_bang: /#{NAME_START}#{NOT_A_DEFINITION}(?:increment|decrement|toggle)!/,
        dependent: /dependent:\s*:(?:delete_all|delete|nullify)\b/,
        delete_without_argument: /\.delete\b(?![(?!\w])(?!\s+(?!#{KEYWORD})[:\w@'"\[])/,
        delete_symbol: /&:delete\b(?![\w?!])/,
        delete_on_constant: /\b(?!ENV\.)[A-Z]\w*(?:::[A-Z]\w*)*\.delete\b(?!\(\s*['"])/,
        delete_on_chain: /(?:[)\]]|\.(?:unscoped|all|class|none|with_deleted|default_scoped))\.delete\b(?!\(\s*['"])(?![?!\w])/,
        delete_continuation: /\A\s*&?\.delete\b(?!\(\s*['"])(?![?!\w])/,
        insert_on_constant: /\b[A-Z]\w*(?:::[A-Z]\w*)*\.insert!?\(/,
        collection_emptied: /\.(?:#{COLLECTIONS.join('|')})\.(?:delete|clear|replace)\b/,
        collection_replaced: /\.(?:#{COLLECTIONS.join('|')}|(?:#{COLLECTION_IDS.join('|')})_ids)\s*=(?![=~>])/
      }.freeze

      # Rules matched in the code WITH its strings (a dynamic send by name).
      STRING_RULES = {
        dynamic_send: /\b(?:send|public_send|__send__|try!?)\(?\s*[:'"](?:#{DYNAMIC})(?![\w?])/
      }.freeze

      # File rules, matched in the whole file (comments out, strings in),
      # across lines. DML in any case; a bare TRUNCATE only in upper case
      # (lower case it is English, or String#truncate).
      SQL_RULES = {
        raw_sql: [
          /\bdelete\s+from\s+[\w"`\[\#]/i,
          /\binsert\s+into\s+[\w"`\[\#]/i,
          /\bupdate\s+\S+\s+set\s+[\w"`\[\]\#{}.]+\s*=/i,
          /\btruncate\s+table\b/i,
          /\bTRUNCATE\s+[\w"`\[\#]/,
          /\bconnection\.truncate(?:_tables)?\b|\.truncate_tables\b/
        ]
      }.freeze

      # [file, pattern on the line, reason]: the only writes past callbacks
      # the gem makes. Every entry must still match something.
      ALLOWLIST = [
        ['lib/permission_forge/services/audit_event_purger.rb', /AuditEvent\.unscoped\.where\(id: ids\)\.delete_all/,
         'retention purge: deletes AuditEvent rows older than audit_retention_period and records audit.purged'],
        ['lib/permission_forge/services/data_subject_erasure.rb', /update_all\(actor_label: nil\)/,
         'GDPR erasure: clears the erased person\'s name snapshots on AuditEvent (ids kept), recorded by erasure.performed'],
        ['lib/permission_forge/services/data_subject_erasure.rb', /update_all\(record_label: nil\)/,
         'GDPR erasure: clears the erased person\'s name snapshots on AuditEvent (ids kept), recorded by erasure.performed'],
        ['lib/generators/permission_forge/upgrade/templates/add_resource_fields_unique_index.rb.tt', /DELETE FROM/,
         'one-time de-duplication of resource_fields before the unique index, in the host\'s migration (not at runtime)']
      ].freeze

      Hit = Struct.new(:file, :line_number, :line, :rule) do
        def to_s = "#{file}:#{line_number} [#{rule}] #{line.strip}"
      end

      def self.hits
        GLOBS.flat_map { |glob| Dir[ROOT.join(glob)] }.uniq.sort.flat_map { |path| hits_in(path) }
      end

      def self.hits_in(path)
        file = Pathname(path).relative_path_from(ROOT).to_s
        erb = file.end_with?('.erb')
        lines = File.readlines(path)
        line_hits = lines.each_with_index.flat_map do |line, index|
          rules_matching(line, erb: erb).map { |name| Hit.new(file, index + 1, line, name) }
        end
        line_hits + sql_hits(file, lines, erb: erb)
      end

      def self.rules_matching(line, erb: false)
        code, bare = scan(line, erb: erb)
        RULES.select { |_name, pattern| bare.match?(pattern) }.keys +
          STRING_RULES.select { |_name, pattern| code.match?(pattern) }.keys
      end

      # SQL in the whole file without its comments: a statement spread over
      # the lines of a heredoc is found; the hit names the line it starts on.
      def self.sql_hits(file, lines, erb: false)
        codes = lines.map { |line| scan(line, erb: erb).first.chomp }
        text = codes.join("\n")
        SQL_RULES.flat_map do |name, patterns|
          sql_line_numbers(text, patterns).map { |number| Hit.new(file, number + 1, lines[number], name) }
        end
      end

      # The (0-based) lines on which a match of any pattern starts.
      def self.sql_line_numbers(text, patterns)
        starts = patterns.flat_map { |pattern| text.to_enum(:scan, pattern).map { Regexp.last_match.begin(0) } }
        starts.map { |start| text[0, start].count("\n") }.uniq.sort
      end

      # The SQL rule for one snippet of code (the self-tests).
      def self.sql_matching(code)
        sql_hits('snippet', code.lines, erb: false).map(&:rule).uniq
      end

      # [the line without its comment, the same with every string literal
      # blanked]. A comment starts at a `#` outside a string that opens no
      # interpolation; an ERB comment is a `<%# %>` tag.
      def self.scan(line, erb: false)
        line = line.gsub(/<%#.*?%>/, '') if erb
        bare = line.gsub(STRING_LITERAL) { |literal| literal[0] + (' ' * (literal.length - 2)) + literal[-1] }
        cut = erb ? nil : bare.index(/#(?!\{)/)
        cut ? [line[0, cut], bare[0, cut]] : [line, bare]
      end

      def self.allowed?(hit)
        ALLOWLIST.any? { |file, pattern, _reason| hit.file == file && hit.line.match?(pattern) }
      end

      test 'no write skips the callbacks of the permission models or touches the audit log outside the allowlist' do
        offenders = self.class.hits.reject { |hit| self.class.allowed?(hit) }

        assert_empty offenders.map(&:to_s), <<~MESSAGE
          These writes skip ActiveRecord callbacks, so they write no audit event. Use save/update!/destroy (or
          destroy_all) so RecordsAuditEvents records the change. If the write is really meant to bypass the
          audit log, add [file, /pattern/, 'one-line reason'] to ALLOWLIST in #{__FILE__}.
        MESSAGE
      end

      test 'every allowlist entry still matches a write and gives a reason' do
        hits = self.class.hits
        ALLOWLIST.each do |file, pattern, reason|
          assert reason.present?, "#{file}: give a reason"
          assert hits.any? { |hit| hit.file == file && hit.line.match?(pattern) }, "stale allowlist entry #{file} #{pattern.inspect}: remove it"
        end
      end

      # --- the matcher ------------------------------------------------------------------

      HITS = {
        'assignment.delete' => :delete_without_argument,
        '@assignment.delete if stale' => :delete_without_argument,
        'rows.each(&:delete)' => :delete_symbol,
        'record.send(:delete)' => :dynamic_send,
        'PermissionSetUser.delete(id)' => :delete_on_constant,
        'PermissionForge::Resource.delete(ids)' => :delete_on_constant,
        'scope.where(user_id: id).delete(ids)' => :delete_on_chain,
        'Model.unscoped.delete(ids)' => :delete_on_chain,
        'PermissionSet.all.delete(ids)' => :delete_on_chain,
        'record.class.delete(id)' => :delete_on_chain,
        '  .delete(ids)' => :delete_continuation,
        'Resource.where(name: n).delete_all' => :bulk_write,
        'expired.in_batches(&:delete_all)' => :bulk_write,
        'rows.update_all(is_editable: true)' => :bulk_write,
        'update_columns(reviewed_at: Time.current)' => :bulk_write,
        '@assignment.public_send(:update_columns, expires_at: 1.day.from_now)' => :bulk_write,
        'field.update_column(:label, x)' => :bulk_write,
        'ResourceField.insert_all(rows)' => :bulk_write,
        'ResourceField.upsert_all(rows)' => :bulk_write,
        'PermissionSet.where(id: id).delete_by(name: n)' => :bulk_write,
        'record.upsert(attrs)' => :bulk_write,
        'PermissionSet.insert(attrs)' => :insert_on_constant,
        '@assignment.touch' => :touch,
        'touch' => :touch,
        'rows.each(&:touch)' => :touch,
        'belongs_to :permission_set, touch: true' => :touch,
        'set.toggle!(:is_active)' => :counter_bang,
        'sets.each(&:toggle!)' => :counter_bang,
        'record.__send__("update_columns", name: x)' => :dynamic_send,
        "record.send 'delete'" => :dynamic_send,
        'has_many :resources, dependent: :delete_all' => :dependent,
        'has_many :permission_sets, dependent: :nullify' => :dependent,
        'set.resources.delete(resource)' => :collection_emptied,
        '@group.permission_sets.clear' => :collection_emptied,
        'group.permission_sets = []' => :collection_replaced,
        'set.permission_set_user_ids = ids' => :collection_replaced,
        'connection.exec_delete(sql)' => :bulk_write
      }.freeze

      SQL_HITS = [
        'execute("DELETE FROM permission_sets WHERE id = 1")',
        'sql = "UPDATE resources SET name = 1"',
        "connection.execute(<<~SQL)\n  UPDATE \#{table}\n  SET is_active = false\nSQL",
        "connection.execute(<<~SQL)\n  UPDATE \#{PermissionForge::PermissionSetUser.table_name}\n  SET reason = 'bulk'\nSQL",
        'execute("update permission_set_users set expires_at = now()")',
        'execute("delete from resources")', 'execute("insert into resources (name) values (1)")',
        'execute("TRUNCATE TABLE permission_sets")', 'connection.truncate(PermissionSet.table_name)',
        'connection.truncate_tables(*tables)'
      ].freeze

      NOT_HITS = [
        'cache_store.delete(prefixed_key(key))', '@entries.delete(user_id)', 'state.delete(KEY)', 'payload.delete(:data)',
        "value.gsub(/x/, '').delete('^a-z0-9_')", 'username.scrub.delete("\\u0000")', 'def touch(*, **)', 'def self.update_counters(*, **)',
        'def upsert_all(*, **)', '# rows.update_all(x: 1) in a comment', 'x = 1 # never call update_columns here',
        '<link rel="apple-touch-icon" href="x">', 'has_many :resources, dependent: :destroy', 'touched = true', 'record.touched?',
        'insert: "permission_forge_insert"', 'delete_prefix("_")', 'resources.delete_if(&:blank?)', 'group.permission_sets == other',
        '"FOR INSERT WITH CHECK (true)"', 'rows.delete_at(0)', "<%= link_to t('permission_forge.ui.delete'), path %>",
        '<%# record.delete %>', "ENV.delete('ACTOR')", 'ENV.delete(key)', 'record.save(touch: false)', 'params.delete :x',
        'hash.delete key', 'name.truncate(40)', 'label.truncate(30, omission: "…")', 't("permission_forge.ui.update_settings")',
        '"Update the set first"', 'PermissionForge::Concerns::Foo::delete_all_cache', 'form_with url: path, method: :delete',
        'CRUD = { destroy: :delete }'
      ].freeze

      test 'the matcher finds raw SQL in any case and across lines' do
        SQL_HITS.each { |code| assert_equal [:raw_sql], self.class.sql_matching(code), code.inspect }
        NOT_HITS.each { |code| assert_empty self.class.sql_matching(code), "#{code.inspect} is no SQL write" }
      end

      test 'the matcher finds each way of writing past callbacks' do
        HITS.each do |line, rule|
          found = self.class.rules_matching(line)
          assert_includes found, rule, "#{line.inspect} is a #{rule} hit (found #{found.inspect})"
        end
      end

      test 'the matcher leaves hashes, caches, strings, comments and definitions alone' do
        NOT_HITS.each do |line|
          found = self.class.rules_matching(line, erb: line.start_with?('<'))
          assert_empty found, "#{line.inspect} is no write past callbacks"
        end
      end
    end
  end
end
