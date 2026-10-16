# frozen_string_literal: true

require 'concurrent/map'

module PermissionForge
  module SchemaRead
    # Whether PostgreSQL can compare values of a type as a rule does (`=`,
    # `<>`, `<`, `>`, `IN`, `BETWEEN`): the type — a domain's base type, a
    # range through `anyrange` — has a default btree operator class whose
    # family holds `=` and `<` for it. `xml`, `point`, `polygon` and `path`
    # have no `=`, `hstore` no `<` (its btree operators are `#<#`...). Asked
    # once per process, database and type (one catalog query, in a savepoint);
    # a type the database does not know (`to_regtype` answers NULL) has none.
    # A failed query answers no for that call only and is asked again next
    # time.
    #
    # @api private
    module OrderedTypes
      @answers = Concurrent::Map.new

      class << self
        # @param model [Class] a model on the connection
        # @param sql_type [String] the column's SQL type, from the schema
        # @return [Boolean]
        def ordered?(model, sql_type)
          key = [model.connection_db_config.name, sql_type.to_s]
          known = @answers[key]
          return known unless known.nil?

          answer = ask(model, sql_type)
          answer.nil? ? false : (@answers[key] = answer)
        end

        # Forgets the answers (tests).
        #
        # @return [void]
        def reset!
          @answers.clear
        end

        private

        # true / false, or nil when the catalog could not be asked (not kept).
        def ask(model, sql_type)
          model.connection_pool.with_connection do |connection|
            connection.transaction(requires_new: true) do
              connection.select_value(sql(connection, sql_type), 'SCHEMA') == true
            end
          end
        rescue ActiveRecord::StatementInvalid
          nil
        end

        def sql(connection, sql_type)
          <<~SQL.squish
            WITH given AS (SELECT COALESCE(NULLIF(t.typbasetype, 0), t.oid) AS oid FROM pg_catalog.pg_type t
                           WHERE t.oid = to_regtype(#{connection.quote(sql_type.to_s)})),
                 input AS (SELECT CASE b.typtype WHEN 'r' THEN to_regtype('anyrange')::oid
                                                 WHEN 'm' THEN to_regtype('anymultirange')::oid ELSE b.oid END AS oid
                           FROM given JOIN pg_catalog.pg_type b ON b.oid = given.oid)
            SELECT COUNT(DISTINCT o.oprname) = 2 FROM input
            JOIN pg_catalog.pg_opclass c ON c.opcintype = input.oid AND c.opcdefault
            JOIN pg_catalog.pg_am a ON a.oid = c.opcmethod AND a.amname = 'btree'
            JOIN pg_catalog.pg_amop ao ON ao.amopfamily = c.opcfamily AND ao.amoplefttype = c.opcintype
                                      AND ao.amoprighttype = c.opcintype
            JOIN pg_catalog.pg_operator o ON o.oid = ao.amopopr AND o.oprname IN ('=', '<')
          SQL
        end
      end
    end
  end
end
