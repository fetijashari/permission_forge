# frozen_string_literal: true

require_relative 'masked_attributes/virtual_readers'
require_relative 'masked_attributes/store_access'
require_relative 'masked_attributes/alias_access'
require_relative 'masked_attributes/validation_reads'

module PermissionForge
  module Concerns
    # Auto-applies field-level read permissions on the model itself by overriding
    # `read_attribute`, `attributes`, every per-column getter, and the
    # `*_for_serialization` hooks. Any path that touches a column — direct getter
    # (`customer.email`), bracket access (`customer[:email]`), `attributes`,
    # `as_json`, `to_json`, `serializable_hash`, AMS, Jbuilder — is enforced.
    #
    # Hidden attributes are *omitted* from `attributes` by default — matching
    # Salesforce `Security.stripInaccessible()` semantics. Configure via
    # {PermissionForge::Configuration#omit_hidden_in_attributes_hash}.
    #
    # NOTE: This does NOT intercept `pluck`, raw SQL, or any path that bypasses
    # the model layer. Use {PermissionForge::Services::FiltersResponseAttributes}
    # for those code paths.
    #
    # Virtual (non-column) readers are covered by {VirtualReaders}, opt-in
    # through config.mask_virtual_attributes. An alias_attribute name reads and
    # writes its attribute, at that attribute's level ({AliasAccess}).
    #
    # With no current user every value is returned as stored, unless
    # config.masked_attributes_nil_user_strategy = :hide, which hides every
    # guarded attribute instead (the primary key and the raw paths excepted),
    # or :hide_in_requests, which does so inside a web request only
    # (PermissionForge::WebRequest). Under :bypass a value returned as stored
    # inside a web request is recorded (field.unmasked_without_user).
    #
    # @example Include in a model
    #   class Customer < ApplicationRecord
    #     include PermissionForge::Concerns::PermissionScopedFindable
    #     include PermissionForge::Concerns::MaskedAttributes
    #   end
    #
    #   customer.email                   # masked / nil / raw based on current_user
    #   customer.read_attribute(:email)  # same
    #   customer.as_json                 # hidden keys omitted entirely
    #
    # @api public
    module MaskedAttributes # rubocop:disable Metrics/ModuleLength
      extend ActiveSupport::Concern

      # The class methods the guard calls. ActiveSupport::Concern extends a
      # concern's own class methods only after it has included the concern,
      # and another thread can read a record of the class in between, through
      # the read_attribute just included. A dependency's class methods are
      # extended before: so they live here.
      #
      # @api private
      module ResourceName
        extend ActiveSupport::Concern

        # Extended into the model by ActiveSupport::Concern.
        module ClassMethods
          # The Resource name a read of this class is reported under, as a
          # Symbol: worked out once per class, not on every read.
          def pf_resource_symbol
            @pf_resource_symbol ||= name.to_sym
          end

          # The Resource names a field of this class is looked up under: its
          # own and its STI ancestors' (ResourceChain), worked out once per
          # class. A read is reported under the first of them.
          def pf_resource_chain
            PermissionForge::ResourceChain.names(self)
          end
        end
      end

      include ResourceName
      include VirtualReaders
      include StoreAccess
      include AliasAccess
      include ValidationReads

      # Raised (when config.masked_write_protection == :raise) if a masked or hidden
      # value read through the getter is written back to the same attribute.
      #
      # @api public
      class MaskedWriteError < StandardError
        def initialize(attribute)
          super("Refusing to persist a masked/hidden value back to '#{attribute}'. " \
                'This usually means a callback read the masked value and wrote it back. ' \
                'Read the raw value via read_attribute_before_type_cast, or set ' \
                'config.masked_write_protection = :skip.')
        end
      end

      # The module a class's masked column getters and guarded setters live in.
      #
      # @api private
      class ColumnAccessors < Module; end

      # Set (an ExecutionState slot) while attribute_for_inspect reads: a
      # debugging read is not a field read.
      INSPECT_KEY = :pf_inspecting

      included do
        next if PermissionForge::Concerns::MaskedAttributes.applied?(self)

        # AR generates per-column reader methods on a dedicated module
        # (`generated_attribute_methods`) and includes it in the model. Calling
        # `customer.email` hits that fast path, bypassing `read_attribute`. We
        # prepend an override module so direct getters (and setters, for the
        # write-back guard) route through our logic: one per column the model
        # has now, and one per column Rails finds each time it defines the
        # attribute methods again (define_attribute_methods below: a column a
        # migration added after the include, once the schema is read again).
        #
        # A getter raises ActiveModel::MissingAttributeError for a column that
        # was not loaded (`select(:id)`), as the getter Rails generates does.
        #
        # Primary key is intentionally never overridden — it's used by routing,
        # association lookups, and tenant scoping (acts_as_tenant calls `id` on
        # the tenant model when computing cache keys). Masking `id` would create
        # a recursion: `id` → guard → `permissions_hash` → `current_tenant.id`.
        masked_attribute_module = ColumnAccessors.new
        PermissionForge::Concerns::MaskedAttributes.define_column_accessors(self, masked_attribute_module)
        prepend(masked_attribute_module)

        const_set(:MaskedAttributeReaders, masked_attribute_module)
        # A subclass that is already loaded may have generated column methods
        # of its own, which it would keep calling: they are removed, so that
        # it finds this class's, as a subclass loaded later does.
        descendants.each do |klass|
          PermissionForge::Concerns::MaskedAttributes.drop_generated_accessors(klass, masked_attribute_module)
        end
        pf_mask_attribute_aliases
        @_pf_masked_attributes_applied = true
      end

      class_methods do
        # Rails defines a model's attribute methods lazily, and again after
        # the schema is read again (reset_column_information — what
        # PermissionForge::SchemaRead does when the database's columns
        # changed): each time, a column the guarded module lacks gets its
        # guarded getter and setter, so `record.new_column` answers what
        # `record[:new_column]` and `as_json` answer. A subclass asks its
        # parent first (Rails), whose module then has the method: Rails
        # generates none of its own for the subclass.
        def define_attribute_methods
          super.tap { |generated| pf_define_late_column_accessors if generated }
        end

        private

        def pf_define_late_column_accessors
          return unless const_defined?(:MaskedAttributeReaders, false)

          PermissionForge::Concerns::MaskedAttributes.define_column_accessors(self, const_get(:MaskedAttributeReaders, false))
        end
      end

      # Defines on `accessors` a guarded getter and setter for every column
      # of `klass` it does not have yet (the primary key never: it is used by
      # routing, associations and tenant scoping). The columns are the ones
      # Rails just loaded for the model (`columns_hash`, ignored columns
      # excluded): those it generates methods for.
      #
      # @param klass [Class]
      # @param accessors [ColumnAccessors]
      # @return [void]
      def self.define_column_accessors(klass, accessors)
        primary_key = klass.primary_key&.to_s
        klass.columns_hash.each_key do |col_name|
          next if col_name.to_s == primary_key || accessors.method_defined?(col_name, false)

          attr_sym = col_name.to_sym
          accessors.define_method(attr_sym) { read_attribute(attr_sym) { |name| missing_attribute(name, caller) } }
          accessors.define_method("#{attr_sym}=") do |value|
            next super(value) unless pf_skip_masked_write?(attr_sym, value)
          end
        end
      end

      # Whether MaskedAttributes has already been applied to a class. Used by the
      # engine's auto-apply to avoid re-prepending the readers module.
      def self.applied?(klass)
        klass.instance_variable_defined?(:@_pf_masked_attributes_applied) &&
          klass.instance_variable_get(:@_pf_masked_attributes_applied)
      end

      # Applied to the class or to a class it inherits from: a subclass is
      # masked through its parent (the concern is never included into it).
      #
      # @param klass [Class]
      # @return [Boolean]
      def self.applied_in_chain?(klass)
        klass.ancestors.any? { |ancestor| ancestor.is_a?(Class) && applied?(ancestor) }
      end

      # Removes from the module Rails generated a subclass's attribute methods
      # into the ones `readers` covers. Rails gives a subclass column methods of
      # its own unless its parent defines them outside such a module, which the
      # parent does from the moment it has the concern; a subclass used before
      # that has them already. Under the lock Rails generates them under, so a
      # generation in progress on another thread is finished first.
      #
      # A method Rails undefined there (reset_column_information) is not found
      # by `remove_method`, and would stop the lookup short of the parent's:
      # it is defined again first, as a call to `super`, then removed.
      def self.drop_generated_accessors(klass, readers)
        generated = klass.send(:generated_attribute_methods)
        with_attribute_methods_lock(generated) do
          readers.instance_methods(false).each do |name|
            generated.define_method(name) { |*args| super(*args) } unless generated.method_defined?(name, false)
            generated.send(:remove_method, name)
          end
        end
      end

      # Rails 7.2 and later generate attribute methods under one lock; 7.1
      # under one per generated module.
      def self.with_attribute_methods_lock(generated, &)
        owner = ActiveRecord::AttributeMethods::GeneratedAttributeMethods
        owner.const_defined?(:LOCK) ? owner::LOCK.synchronize(&) : generated.synchronize(&)
      end
      private_class_method :with_attribute_methods_lock

      # Diagnostic: explains exactly what the guard decided for a given record
      # and attribute, and why. Run from the console when a field returns an
      # unexpected value (nil where you expected raw, raw where you expected masked, etc).
      #
      # @example
      #   PermissionForge::Concerns::MaskedAttributes.explain(customer, :email)
      # rubocop:disable-next Metrics/AbcSize
      def self.explain(record, attr_name)
        config = PermissionForge.configuration
        user = PermissionForge.current_user
        klass = record.class
        chain = PermissionForge::ResourceChain.names(klass)
        raw = record.read_attribute_before_type_cast(attr_name) || record[attr_name]
        field_name = AliasAccess.target(klass, attr_name) || attr_name
        field = PermissionForge::ResourceChain.field_permissions(user, chain, field_name)

        {
          attribute: attr_name,
          class: klass.name,
          resource_chain: chain,
          masked_attributes_applied: applied_in_chain?(klass),
          primary_key: klass.primary_key,
          is_primary_key: klass.primary_key.to_s == attr_name.to_s,
          current_user_present: !user.nil?, **explain_without_user(config, klass),
          user_responds_to_field_permissions: user.respond_to?(:field_permissions),
          resource_in_permissions_hash: entries?(user, chain),
          field_configured: !field.nil?,
          field_entry: field,
          unconfigured_field_strategy: config.unconfigured_field_strategy,
          omit_hidden_in_attributes_hash: config.omit_hidden_in_attributes_hash,
          raw_value: raw,
          returned_value: record.public_send(attr_name)
        }
      end

      # What explain reports about reads with nobody signed in.
      def self.explain_without_user(config, klass)
        { masked_attributes_nil_user_strategy: config.masked_attributes_nil_user_strategy,
          user_model_exempt: config.user_model_class?(klass), in_web_request: PermissionForge::WebRequest.active? }
      end
      private_class_method :explain_without_user

      # Whether the user's hash has a resource entry along the chain.
      def self.entries?(user, chain)
        user.respond_to?(:permissions_hash) && PermissionForge::ResourceChain.entries(user, chain).any?
      end
      private_class_method :entries?

      # Diagnostic: walks every column and virtual reader on the record and reports
      # raw vs. returned, plus the decision the guard made (passed / masked / hidden /
      # unconfigured / bypassed). A virtual reader that is not masked on the model
      # (config.mask_virtual_attributes off for it) reports :virtual_masking_off.
      # Prints a readable table to stdout and returns the rows for programmatic use.
      #
      # @example
      #   PermissionForge::Concerns::MaskedAttributes.explain_all(customer)
      def self.explain_all(record)
        klass = record.class
        rows = klass.column_names.map { |col| explain_row(record, col, record[col]) } +
               virtual_reader_names(record).map { |name| explain_virtual_row(record, name) }
        print_explain_table(rows)
        rows
      end

      def self.explain_row(record, attr_name, raw)
        klass = record.class
        user = PermissionForge.current_user
        field = PermissionForge::ResourceChain.field_permissions(user, PermissionForge::ResourceChain.names(klass), attr_name)

        decision = decide(attr_name: attr_name, klass: klass, user: user, field: field)

        { attribute: attr_name, decision: decision, configured: !field.nil?,
          read_access: field&.dig(:read_access), mask_access: field&.dig(:mask_access),
          mask_strategy: field&.dig(:mask_strategy), raw: raw, returned: record.public_send(attr_name), virtual: false }
      end
      private_class_method :explain_row

      # The model's virtual fields that have a reader, masked on the model or not.
      def self.virtual_reader_names(record)
        klass = record.class
        klass.respond_to?(:pf_virtual_readers) ? klass.pf_virtual_readers : []
      end
      private_class_method :virtual_reader_names

      def self.explain_virtual_row(record, name)
        raw = record.pf_without_virtual_masking { record.public_send(name) }
        row = explain_row(record, name, raw).merge(virtual: true)
        VirtualReaders.masked?(record.class, name) ? row : row.merge(decision: :virtual_masking_off)
      end
      private_class_method :explain_virtual_row

      def self.decide(attr_name:, klass:, user:, field:)
        return :primary_key_skipped if attr_name.to_s == klass.primary_key.to_s
        return without_user_decision(klass) if user.nil?
        return :unconfigured if field.nil?
        return :hidden_no_read_access unless field[:read_access]
        return :masked if field[:mask_access]

        :passed_raw
      end
      private_class_method :decide

      # What the guard does with no user (config.masked_attributes_nil_user_strategy;
      # the user model is exempt from :hide and :hide_in_requests).
      def self.without_user_decision(klass)
        config = PermissionForge.configuration
        return :no_user_hidden if config.hide_masked_attributes_without_user_for?(klass)
        return :no_user_user_model_exempt if config.hide_masked_attributes_without_user_in_requests? && config.user_model_class?(klass)

        :no_user_bypassed
      end
      private_class_method :without_user_decision

      def self.print_explain_table(rows)
        return if rows.empty?

        Rails.logger&.info('[PermissionForge.explain_all]')
        rows.each do |r|
          line = format(
            '%<attribute>-22s decision=%<decision>-22s configured=%<configured>-5s raw=%<raw>s -> returned=%<returned>s',
            attribute: r[:attribute], decision: r[:decision], configured: r[:configured],
            raw: r[:raw].inspect, returned: r[:returned].inspect
          )
          puts line
        end
      end
      private_class_method :print_explain_table

      # Forgets the attributes read as hidden with nobody signed in
      # (pf_hidden_without_user_reads): the record holds fresh values.
      def reload(*)
        pf_forget_hidden_without_user_reads
        super
      end

      # Reads an attribute through the field permissions of the current user.
      # @param attr_name [String, Symbol]
      def read_attribute(attr_name, &)
        name = attr_name.to_s
        raw = super(name, &)
        # An alias is judged as the attribute it points to (AliasAccess); what
        # is read is what Rails reads for it.
        target = self.class.attribute_aliases[name]
        attr_name = name = pf_alias_end(target) if target
        return raw if pf_read_as_stored?(name)

        user = pf_guarded_user
        include_field, value = pf_guard(attr_name, raw, user)
        unless include_field
          value = PermissionForge.configuration.hidden_attribute_value
          pf_note_hidden_without_user(name, raw) unless user
        end
        # A returned value that differs from the raw column value was masked or
        # hidden; remember the exact sentinel so a write-back of it can be refused.
        pf_record_masked_read(name, value) unless include_field && value == raw
        value
      end

      # The user is resolved once for the whole hash. With no user every
      # value is returned as stored (or hidden, under
      # config.masked_attributes_nil_user_strategy = :hide, and :hide_in_requests
      # inside a web request); the decisions (bypassed) are still published,
      # as for a getter or as_json, but only when someone listens, and each
      # attribute returned as stored inside a web request is recorded
      # (field.unmasked_without_user).
      def attributes
        raw = super
        user = pf_guarded_user
        return raw unless user || pf_guard_without_user? || PermissionForge::Audit::FieldAccess::GATE.open?

        PermissionForge::Audit::FieldAccess.read(self, self.class.name, record: self) do
          pf_guard_attributes_hash(raw, user)
        end
      end

      # as_json / to_json / serializable_hash: one read of the record, so one
      # field.access event for all the fields it serializes.
      def serializable_hash(options = nil)
        PermissionForge::Audit::FieldAccess.read(self, self.class.name, record: self) { super }
      end

      # Hook used by ActiveModel::Serialization (and therefore as_json / to_json /
      # serializable_hash). Filtering the *names* here means hidden keys never get
      # serialized at all — matching Salesforce stripInaccessible semantics.
      def attribute_names_for_serialization
        names = super
        user = pf_guarded_user
        return names unless user || pf_hide_without_user?
        return names unless PermissionForge.configuration.omit_hidden_in_attributes_hash

        hidden, shown = names.partition { |name| pf_hidden_attribute?(name, user) }
        PermissionForge::Audit::FieldAccess.omitted(self, self.class.pf_resource_symbol, hidden, user) unless hidden.empty?
        shown
      end

      # AR's default routes through `send(name)` which hits the AR attribute fast
      # path and bypasses our `read_attribute` override. Routing real columns
      # through `read_attribute` lets the masking logic apply during serialization.
      # Virtual attributes (defined as methods) still go through the original path.
      # A column that was not loaded raises, as that original path does.
      def read_attribute_for_serialization(name)
        if self.class.attribute_names.include?(name.to_s)
          read_attribute(name) { |missing| missing_attribute(missing, caller) }
        else
          super
        end
      end

      # What inspect, pretty_print and the console print for an attribute: the
      # value the current user's getter returns, formatted as Rails formats it
      # (filter_attributes still apply on top). Rails reads the raw attribute
      # here, so a record in a log line or an error report used to show masked
      # and hidden values in full. Not a field read: no field.access decision,
      # no hook. And never an error: inspect runs inside error reporters and
      # rescue blocks, often in the failed transaction itself, so a read that
      # fails — or a Rails formatting of the value that fails (a private
      # method, renamed some day) — shows the hidden value, never the stored
      # one.
      def attribute_for_inspect(attr_name)
        name = attr_name.to_s
        name = self.class.attribute_aliases[name] || name
        pf_while_inspecting { format_for_inspect(name, read_attribute(name)) }
      rescue StandardError
        pf_hidden_for_inspect
      end

      # Rails 7.1 reads the raw attribute in pretty_print; 7.2 and later print
      # attribute_for_inspect. The 7.2 listing, for 7.1.
      if ActiveRecord.gem_version < Gem::Version.new('7.2')
        # Prints the record without revealing masked or hidden values.
        def pretty_print(pp)
          return super if custom_inspect_method_defined?

          pp.object_address_group(self) do
            next pf_pp_not_initialized(pp) unless defined?(@attributes) && @attributes

            attr_names = self.class.attribute_names.select { |name| _has_attribute?(name) }
            pp.seplist(attr_names, proc { pp.text ',' }) { |attr_name| pf_pp_attribute(pp, attr_name) }
          end
        end

        def pf_pp_attribute(pp, attr_name)
          pp.breakable ' '
          pp.group(1) do
            pp.text attr_name
            pp.text ':'
            pp.breakable
            pp.text attribute_for_inspect(attr_name)
          end
        end

        def pf_pp_not_initialized(pp)
          pp.breakable ' '
          pp.text 'not initialized'
        end
        private :pf_pp_attribute, :pf_pp_not_initialized
      end

      private

      # Whether the user's entry for `name`, along this class's resource
      # chain, denies read. False for an unconfigured field. With no user:
      # false, or true for everything but the primary key under :hide.
      def pf_hidden_attribute?(name, user = pf_guarded_user)
        return pf_hide_without_user? && name.to_s != self.class.primary_key unless user

        field = PermissionForge::ResourceChain.field_permissions(user, self.class.pf_resource_chain, name)
        field ? !field[:read_access] : false
      end

      # The primary key is never masked; a store column is read as stored
      # while a store accessor writes one of its keys (StoreAccess), and the
      # column a validator reads while it reads it (ValidationReads).
      def pf_read_as_stored?(name)
        name == self.class.primary_key || pf_raw_store_column?(name) || name == pf_validation_read
      end

      # config.masked_attributes_nil_user_strategy = :hide (and
      # :hide_in_requests inside a web request) — with no user every guarded
      # attribute is hidden (AttributeAccessGuard#without_user), except on
      # the user model, which sign-in reads before anyone is signed in.
      def pf_hide_without_user?
        PermissionForge.configuration.hide_masked_attributes_without_user_for?(self.class)
      end

      # Whether a read with no user goes through the guard attribute by
      # attribute: it hides them, or records them (inside a web request
      # under :bypass, while there is something left to record).
      def pf_guard_without_user?
        case PermissionForge.configuration.masked_attributes_without_user_for(self.class)
        when :hide then true
        when :record then PermissionForge::Audit::UnmaskedWithoutUser.pending?(self.class)
        else false
        end
      end

      # Every guarded read of this record is one field.access read
      # (Audit::FieldAccess), joined by the reads made inside it. Nobody
      # listening (the gate is shut): one check, nothing collected.
      def pf_guard(attr_name, raw, user = pf_guarded_user)
        chain = self.class.pf_resource_chain
        unless PermissionForge::Audit::FieldAccess::GATE.open? && !PermissionForge::ExecutionState[INSPECT_KEY]
          return PermissionForge::Services::AttributeAccessGuard.call(
            resource_name: chain, attribute: attr_name, raw_value: raw, user: user, observer: nil, model: self.class
          )
        end

        PermissionForge::Audit::FieldAccess.read(self, self.class.name, record: self) do |frame|
          PermissionForge::Services::AttributeAccessGuard.call(
            resource_name: chain, attribute: attr_name, raw_value: raw, user: user, observer: frame, model: self.class
          )
        end
      end

      # Marks the reads in the block as debugging reads: no field.access
      # decision, no hook.
      def pf_while_inspecting(&)
        PermissionForge::ExecutionState.with(INSPECT_KEY, true, &)
      end

      # What inspect prints for an attribute whose read or formatting failed:
      # the hidden value as inspect prints it — a String whatever the
      # configured value is, so inspect itself never raises.
      def pf_hidden_for_inspect
        PermissionForge.configuration.hidden_attribute_value.inspect
      rescue StandardError
        'nil'
      end

      # Per-instance record of the exact masked/hidden sentinel handed out for
      # each attribute, keyed by attribute name string.
      def pf_masked_reads
        @pf_masked_reads ||= {}
      end

      def pf_record_masked_read(attr_name, sentinel)
        pf_masked_reads[attr_name.to_s] = sentinel
      end

      # The attributes this instance read as hidden because nobody was signed
      # in (masked_attributes_nil_user_strategy :hide, or :hide_in_requests in a
      # web request) while they held a value. Whatever is written to one of
      # them afterwards was worked out from the hidden value, or replaces a
      # value nobody could see: pf_skip_masked_write? treats it as a
      # write-back. Only something real counts: a value the record holds in
      # memory, stored or assigned (an empty column, or an attribute of a new
      # record nobody filled, hides nothing: a default or a fill-if-blank is
      # written; a value submitted on a new record is kept from a normalizer
      # that reads it). The value is the one just read, not
      # attribute_in_database, which would build the record's mutation
      # tracker on every hidden read. A debugging read (inspect) does not
      # count. Forgotten on reload only: a save does not make the hidden read
      # visible, so a value derived from it before the save is still refused
      # after it.
      def pf_hidden_without_user_reads
        @pf_hidden_without_user_reads ||= Set.new
      end

      def pf_note_hidden_without_user(attr_name, value)
        return if value.nil? || PermissionForge::ExecutionState[INSPECT_KEY]

        pf_hidden_without_user_reads << attr_name.to_s
      end

      def pf_forget_hidden_without_user_reads
        @pf_hidden_without_user_reads = nil
      end

      # True when the guard should suppress this write because `value` is a masked/
      # hidden sentinel being written back over real data. Honors
      # config.masked_write_protection. Two detections:
      #   1. Ledger — this instance handed out that exact sentinel earlier (covers
      #      same-instance read-modify-write, e.g. a before_save callback).
      #   2. Hidden without a user — this instance read the attribute as hidden
      #      because nobody was signed in: any value written to it was derived
      #      from the hidden one (`self.name = name.to_s.strip` stores "") or
      #      replaces a value nobody could see.
      #   3. Stateless — `value` equals what the mask would produce for the value
      #      CURRENTLY persisted in the DB. This survives a request boundary: a form
      #      rendered "********" and submitted back onto a freshly-loaded record has
      #      no ledger entry, but still matches the persisted value's mask.
      def pf_skip_masked_write?(attr_name, value)
        protection = PermissionForge.configuration.masked_write_protection
        return false if protection == :off

        detected_by = pf_masked_write_detection(attr_name.to_s, value)
        return false unless detected_by

        pf_masked_write_refused(attr_name, protection, detected_by)
        PermissionForge::Audit::UnmaskedWithoutUser.write_refused(self.class, attr_name, protection) if detected_by == 'hidden_without_user'
        raise MaskedWriteError, attr_name if protection == :raise

        true # :skip — preserve the stored value by not calling super
      end

      # How a write was recognised as a write-back (write.masked_skipped
      # `detected_by`), nil for a write that is not one.
      def pf_masked_write_detection(name, value)
        return 'ledger' if pf_masked_reads.key?(name) && pf_masked_reads[name] == value
        return 'hidden_without_user' if pf_hidden_without_user_reads.include?(name)

        'persisted_value' if pf_matches_persisted_sentinel?(name, value)
      end

      # write.masked_skipped: which attribute, how it was refused (:skip
      # keeps the stored value, :raise raised) and how the sentinel was
      # recognised. Never the value.
      def pf_masked_write_refused(attr_name, protection, detected_by)
        event = 'write.masked_skipped'
        return unless PermissionForge::Audit.instrument?(event)

        user = PermissionForge.current_user
        PermissionForge::Audit.instrument(event) do
          { record: self, subject_user_id: PermissionForge::Audit::Runtime.user_id(user),
            data: { 'model' => self.class.name, 'attribute' => attr_name.to_s, 'protection' => protection.to_s,
                    'detected_by' => detected_by },
            objects: { user: user, record: self } }
        end
      end

      # True when `value` equals the masked/hidden sentinel derived from the value
      # currently persisted in the database for this attribute, and differs from
      # that persisted value (writing the same value is a harmless no-op either way).
      def pf_matches_persisted_sentinel?(attr_name, value)
        field = pf_current_field_permissions(attr_name)
        return false unless field
        return value == PermissionForge.configuration.hidden_attribute_value unless field[:read_access]
        return false unless field[:mask_access]

        pf_persisted_mask_matches?(attr_name, value, field[:mask_strategy])
      end

      def pf_current_field_permissions(attr_name)
        PermissionForge::ResourceChain.field_permissions(PermissionForge.current_user, self.class.pf_resource_chain, attr_name)
      end

      def pf_persisted_mask_matches?(attr_name, value, strategy)
        persisted = attribute_in_database(attr_name.to_s)
        sentinel = PermissionForge::Services::MaskValue.call(persisted, strategy: strategy || 'full')
        value == sentinel && value != persisted
      end

      def pf_guard_attributes_hash(raw, user)
        omit_hidden = PermissionForge.configuration.omit_hidden_in_attributes_hash
        hidden_value = PermissionForge.configuration.hidden_attribute_value

        primary_key = self.class.primary_key.to_s
        raw.filter_map do |key, value|
          # The primary key is never guarded (read_attribute and as_json keep it).
          next [key, value] if key.to_s == primary_key

          include_field, masked = pf_guard(key, value, user)
          next [key, masked] if include_field

          pf_note_hidden_without_user(key, value) unless user
          next if omit_hidden

          [key, hidden_value]
        end.to_h
      end

      def pf_guarded_user
        PermissionForge.current_user
      end
    end
  end
end
