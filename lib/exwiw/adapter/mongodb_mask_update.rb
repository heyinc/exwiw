# frozen_string_literal: true

module Exwiw
  module Adapter
    # Mask-update generation for MongoDB: reads the documents by primary key, masks a copy with
    # the same mask plan export uses, and emits a mongosh bulkWrite of `$set`s for what changed.
    module MongodbMaskUpdate
      # @param config [Exwiw::MongodbCollectionConfig] collection to mask
      # @param dump_target [Exwiw::DumpTarget] names the documents to mask by their primary keys (`default_ids`)
      # @param allow_constant_columns [Array<String>] credential-looking "collection.path"s accepted as non-NULL masks
      # @return [Exwiw::MaskUpdatePlan::Generated]
      def build_mask_update(config, dump_target, config_by_name = nil, allow_constant_columns: [])
        config_by_name = (config_by_name || { config.name => config }).transform_values { |c| c.dup.reject_ignored_members! }
        config = config_by_name.fetch(config.name)
        @embedded_children_by_parent = index_embedded_children(config_by_name)

        plan = build_mask_plan(config)
        names = mask_target_names(plan)
        if names.empty?
          raise MaskUpdatePlan::Error, "collection '#{config.name}' declares no mask (replace_with / replace_with_fake_data) on any field"
        end
        if names.include?(config.primary_key)
          raise MaskUpdatePlan::Error, "collection '#{config.name}' masks '#{config.primary_key}', which is immutable in MongoDB"
        end
        # A MongoDB mask can neither say NULL nor draw random bytes, so a credential-looking path always needs an allowance.
        safe_paths = names.map { |n| [n, false] }
        allowed = MaskUpdatePlan.check_credential_columns!(config.name, safe_paths, allow_constant_columns)

        primary_key_values = dump_target.default_ids
        ids = coerce_ids(primary_key_values)
        docs = find_for_mask_update(config, ids)
        found_ids = docs.to_set { |doc| doc[config.primary_key] }
        missing = primary_key_values.zip(ids).reject { |_, id| found_ids.include?(id) }.map(&:first)

        operations = docs.filter_map do |doc|
          masked = copy_containers(doc)
          apply_mask_plan!(masked, plan)
          sets = changed_paths(doc, masked)
          next if sets.empty?

          "  { updateOne: { filter: { #{js_literal(config.primary_key)}: #{js_literal(doc[config.primary_key])} }, " \
            "update: { \"$set\": { #{sets.map { |path, value| "#{js_literal(path)}: #{js_literal(value)}" }.join(', ')} } } } }"
        end
        statements = operations.each_slice(MaskUpdatePlan::CHUNK_SIZE).map do |chunk|
          "db.getCollection(#{js_literal(config.name)}).bulkWrite([\n#{chunk.join(",\n")}\n]);"
        end

        MaskUpdatePlan::Generated.new(
          statements: statements,
          target_count: docs.size,
          columns: names,
          missing_primary_key_values: missing,
          allowed_constant_columns: allowed,
        )
      end

      private def mask_target_names(plan, prefix = nil)
        own = (plan.masked_fields.map(&:first) + plan.faked_fields.map(&:first)).map { |n| [prefix, n].compact.join(".") }
        own + plan.embedded.flat_map { |e| mask_target_names(e.plan, [prefix, *e.prefix, e.last].compact.join(".")) }
      end

      private def find_for_mask_update(config, ids)
        opts = config.query_timeout_ms ? { timeout_ms: config.query_timeout_ms } : {}
        ids.each_slice(MaskUpdatePlan::CHUNK_SIZE).flat_map do |chunk|
          db[config.name].find({ config.primary_key => { "$in" => chunk } }, opts)
            .projection(build_projection(config))
            .comment(query_comment_text("mask-update collection=#{config.name}"))
            .to_a
        end
      end

      private def copy_containers(value)
        case value
        when Hash then value.to_h { |k, v| [k, copy_containers(v)] }
        when Array then value.map { |v| copy_containers(v) }
        else value
        end
      end

      # Dotted path => new value for every changed leaf; keys export drops are absent from `masked`, so never $set or $unset.
      private def changed_paths(original, masked, prefix = nil, out = {})
        case masked
        when Hash
          masked.each { |k, v| changed_paths(original.is_a?(Hash) ? original[k] : nil, v, [prefix, k].compact.join("."), out) }
        when Array
          masked.each_with_index do |v, i|
            changed_paths(original.is_a?(Array) ? original[i] : nil, v, [prefix, i].compact.join("."), out)
          end
        else
          out[prefix] = masked unless original == masked
        end
        out
      end

      private def js_literal(value)
        case value
        when nil then "null"
        when true, false then value.to_s
        when Integer then value.between?(-2**31, 2**31 - 1) ? value.to_s : "NumberLong(\"#{value}\")"
        when Float
          raise MaskUpdatePlan::Error, "cannot express #{value} in a mongosh script" unless value.finite?

          "Double(#{value})"
        when String then JSON.generate(value)
        when BSON::ObjectId then "ObjectId(\"#{value}\")"
        else raise MaskUpdatePlan::Error, "cannot express a #{value.class} value in a mongosh script"
        end
      end
    end
  end
end
