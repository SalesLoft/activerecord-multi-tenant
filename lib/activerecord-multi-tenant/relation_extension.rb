# frozen_string_literal: true

module Arel
  module ActiveRecordRelationExtension
    # Overrides the delete_all method to include tenant scoping
    def delete_all
      # Call the original delete_all method if the current tenant is identified by an ID
      return super if MultiTenant.current_tenant_is_id? || MultiTenant.current_tenant.nil?

      stmt = Arel::DeleteManager.new.from(table)
      stmt.wheres = [generate_in_condition_subquery]

      # Execute the delete statement using the connection and return the result
      klass.connection.delete(stmt, "#{klass} Delete All").tap { reset }
    end

    # Overrides the update_all method to include tenant scoping
    def update_all(updates)
      # Call the original update_all method if the current tenant is identified by an ID
      return super if MultiTenant.current_tenant_is_id? || MultiTenant.current_tenant.nil?

      if updates.is_a?(Hash)
        if klass.locking_enabled? &&
           !updates.key?(klass.locking_column) &&
           !updates.key?(klass.locking_column.to_sym)
          attr = table[klass.locking_column]
          updates[attr.name] = _increment_attribute(attr)
        end
        values = _substitute_values(updates)
      else
        values = Arel.sql(klass.sanitize_sql_for_assignment(updates, table.name))
      end

      stmt = Arel::UpdateManager.new
      stmt.table(table)
      stmt.set values
      stmt.wheres = [generate_in_condition_subquery]

      klass.connection.update(stmt, "#{klass} Update All").tap { reset }
    end

    private

    # The generate_in_condition_subquery method generates a subquery that selects
    # records associated with the current tenant.
    def generate_in_condition_subquery
      # Get the tenant key and tenant ID based on the current tenant
      tenant_key = MultiTenant.partition_key(MultiTenant.current_tenant_class)
      tenant_id = MultiTenant.current_tenant_id

      # Build an Arel query
      arel = if eager_loading?
               apply_join_dependency.arel
             elsif ActiveRecord.gem_version >= Gem::Version.create('7.2.0')
               build_arel(klass.connection)
             else
               build_arel
             end

      arel.source.left = table

      # If the tenant ID is present and the tenant key is a column in the model,
      # add a condition to only include records where the tenant key equals the tenant ID
      if tenant_id && klass.column_names.include?(tenant_key)
        tenant_condition = table[tenant_key].eq(tenant_id)
        unless arel.constraints.any? { |node| node.to_sql.include?(tenant_condition.to_sql) }
          arel = arel.where(tenant_condition)
        end
      end

      # Clone the query, clear its projections, and set its projection to the primary key of the table
      subquery = arel.clone
      subquery.projections.clear

      # Handle composite primary keys
      primary_keys = Array.wrap(table[primary_key].name).map { |key| table[key] }
      subquery.project(*primary_keys)

      group_values_arel_columns = arel_columns(group_values.uniq)

      # Generate the subquery for group_values and having_clause
      if group_values_arel_columns.any? || having_clause.present?
        group_subquery = table
                         .project(*group_values_arel_columns)
                         .where(arel.constraints)
                         .group(*group_values_arel_columns)
        having_clause_ast = having_clause.ast unless having_clause.empty?
        group_subquery.having(having_clause_ast) if having_clause_ast

        # Handle multiple columns in the group_values_arel_columns
        if group_values_arel_columns.size > 1
          subquery.where(Arel::Nodes::Grouping.new(group_values_arel_columns).in(group_subquery))
        else
          subquery.where(group_values_arel_columns.first.in(group_subquery))
        end

        # Clear group_values and having_clause from the subquery
        subquery.ast.cores.first.groups.clear
        subquery.ast.cores.first.havings.clear
      end

      # Create an IN condition node with the primary key of the table and the subquery
      if primary_keys.size > 1
        Arel::Nodes::In.new(Arel::Nodes::Grouping.new(primary_keys),
                            Arel::Nodes::Grouping.new(subquery.ast))
      else
        Arel::Nodes::In.new(primary_keys.first, subquery.ast)
      end
    end
  end
end

# Patch ActiveRecord::Relation with the extension module
ActiveRecord::Relation.prepend(Arel::ActiveRecordRelationExtension)
