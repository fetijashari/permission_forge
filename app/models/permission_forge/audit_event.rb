module PermissionForge
  # One audit event: who did what, to what, when, and what it was before.
  # Written by PermissionForge::Audit only; insert-only once persisted
  # (update, destroy and delete raise). The purge service deletes through a
  # relation (`delete_all`), past the retention period, and records that.
  #
  # `data` is JSON text in the database and a Hash with string keys here:
  # { "changes" => { attr => [from, to] } } on an update, { "snapshot" => {...} }
  # on a create or destroy, plus event-specific keys.
  #
  # @api public
  class AuditEvent < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}audit_events"

    include PermissionForge::Concerns::HasTenantScoping

    # A system event of a cross-tenant task (a rake clean-up, a report) has
    # no tenant; it is visible while none is set, like any untenanted row.
    def self.tenant_scoping_options
      { optional: true }
    end

    CATEGORIES = PermissionForge::Audit::EventCatalog::CATEGORIES
    ACTOR_TYPES = PermissionForge::Audit::Actor::TYPES
    SOURCES = PermissionForge::Audit::Source::SOURCES

    # actor_label and record_label name people: #inspect hides them whenever
    # the application's filters hide a `name` (InspectionFilters).
    PermissionForge::InspectionFilters.hide_people_labels(self)

    # JSON text that works on SQLite, PostgreSQL and MySQL alike; times are
    # written in ISO 8601 (ActiveSupport::JSON), nothing reads as nil.
    #
    # @api private
    class DataCoder
      def self.dump(value)
        ActiveSupport::JSON.encode(value.nil? ? {} : value)
      end

      def self.load(value)
        value.blank? ? {} : ActiveSupport::JSON.decode(value)
      end
    end

    serialize :data, coder: DataCoder

    # The tenant of the record the event is about. acts_as_tenant writes the
    # ambient tenant to every new row (before_validation); an event follows
    # its subject instead (before_create runs after validation).
    attr_accessor :subject_tenant_id

    before_validation :assign_uuid, on: :create
    before_create :follow_subject_tenant

    validates :uuid, :event, :category, :actor_type, :source, :occurred_at, presence: true
    validates :category, inclusion: { in: CATEGORIES }
    validates :actor_type, inclusion: { in: ACTOR_TYPES }
    validates :source, inclusion: { in: SOURCES }

    scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }
    scope :for_record, ->(record) { where(record_type: record.class.base_class.name, record_id: record.id.to_s) }
    scope :for_subject, ->(user_id) { where(subject_user_id: user_id.to_s) }
    scope :between, ->(from, to) { where(occurred_at: from..to) }

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    # The tenant column of the events: nil when tenancy is off or the table
    # has no such column (installed before tenancy), where events cannot be
    # told apart by tenant.
    #
    # @return [Symbol, nil]
    def self.tenant_column
      column = PermissionForge.configuration.resolved_tenant_column
      column if column && PermissionForge::SchemaRead.column?(self, column.to_s, ignored: false)
    end

    # The events of one tenant, on the relation it is called on; every event
    # when there is no tenant id or no tenant column. Used by the services
    # that work past the default scope (`unscoped`): erasure, the purge.
    #
    # @param tenant_id [Object, nil]
    # @return [ActiveRecord::Relation]
    def self.in_tenant(tenant_id)
      column = tenant_column
      tenant_id && column ? where(column => tenant_id) : all
    end

    # The one write (Audit::Recorder). Built under `unscoped`: instantiating
    # a model that has a default scope evaluates it (Rails fills in scope
    # attributes), and acts_as_tenant's raises under require_tenant when no
    # tenant is ambient — a job, a rake task. The tenant comes from the
    # subject (subject_tenant_id), else from the ambient tenant.
    #
    # @param attributes [Hash] columns plus subject_tenant_id:
    # @return [AuditEvent] persisted
    # @raise [ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid]
    def self.store!(attributes)
      event = unscoped { new(attributes) }
      event.save!
      event
    end

    # Insert-only. On a persisted event these raise ActiveRecord::ReadOnlyRecord:
    # save, save!, update, update!, update_attribute, update_column(s), touch,
    # toggle!, increment!, decrement! (through update_counters), destroy,
    # destroy!, delete, becomes + save, Class.update(id), Class.destroy(id),
    # Class.update_counters and relation.update_counters, Class.upsert and Class.upsert_all,
    # relation.destroy_all. Still reachable, on purpose: relation.update_all
    # (the erasure service clears label snapshots of an erased person — the
    # one sanctioned mutation, recorded itself), relation.delete_all and
    # Class.delete(id) (the purge service, past the retention period). Protect
    # the table at the database level too (REVOKE UPDATE, DELETE).
    def readonly?
      persisted?
    end

    # `delete` skips the read-only check Rails makes elsewhere.
    def delete
      raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly" if persisted?

      super
    end

    # upsert / upsert_all would rewrite an existing row through its uuid, and
    # update_counters is how increment! / decrement! write, past the
    # instance (through the class up to Rails 8.1, through a relation —
    # `unscoped.where(id:).update_counters` — on Rails main). Class methods
    # on Rails 7.1; Relation methods the class delegates to from 7.2 on —
    # refused in both places.
    #
    # @api private
    module InsertOnly
      def update_counters(*, **)
        raise ActiveRecord::ReadOnlyRecord, 'PermissionForge::AuditEvent is insert-only: counters cannot be updated'
      end

      def upsert_all(*, **)
        raise ActiveRecord::ReadOnlyRecord, 'PermissionForge::AuditEvent is insert-only: rows cannot be upserted'
      end

      def upsert(*, **)
        raise ActiveRecord::ReadOnlyRecord, 'PermissionForge::AuditEvent is insert-only: rows cannot be upserted'
      end
    end
    singleton_class.prepend(InsertOnly)
    relation_delegate_class(ActiveRecord::Relation).prepend(InsertOnly)

    private

    # No uniqueness validation (a query per insert): the unique index holds.
    def assign_uuid
      self.uuid = PermissionForge.configuration.uuid_generator.call if uuid.blank?
    end

    def follow_subject_tenant
      column = PermissionForge.configuration.resolved_tenant_column
      return if subject_tenant_id.nil? || column.nil? || !has_attribute?(column)

      write_attribute(column, subject_tenant_id)
    end
  end
end
