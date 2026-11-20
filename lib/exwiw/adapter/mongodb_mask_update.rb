# frozen_string_literal: true

module Exwiw
  module Adapter
    # Mask-update generation for MongoDB: reads the documents by primary key, masks a copy with
    # the same mask plan export uses, and emits a mongosh bulkWrite of `$set`s for what changed.
    module MongodbMaskUpdate
      # Checks that `config` can be masked as declared, before any document is read.
      #
      # @param config [Exwiw::MongodbCollectionConfig] collection to mask
      # @param config_by_name [Hash{String => Exwiw::MongodbCollectionConfig}] every declared collection by name
      # @param allow_constant_columns [Array<String>] credential-looking "collection.path"s accepted as non-NULL masks
      # @return [Exwiw::MaskUpdateRunner::Checked]
      # @raise [Exwiw::MaskUpdateRunner::Error] when the collection declares no mask or masks its primary key, or for an unaccepted credential-looking path
      def check_mask_update(config, config_by_name, allow_constant_columns: [])
        @embedded_children_by_parent = index_embedded_children(config_by_name)

        names = mask_target_names(mask_plan(config))
        if names.empty?
          raise MaskUpdateRunner::Error, "collection '#{config.name}' declares no mask (replace_with / replace_with_fake_data) on any field"
        end
        if names.include?(config.primary_key)
          raise MaskUpdateRunner::Error, "collection '#{config.name}' masks '#{config.primary_key}', which is immutable in MongoDB"
        end
        # A MongoDB mask can neither say NULL nor draw random bytes, so a credential-looking path always needs an allowance.
        safe_paths = names.map { |n| [n, false] }
        allowed = MaskUpdateRunner.check_credential_columns!(config.name, safe_paths, allow_constant_columns)

        MaskUpdateRunner::Checked.new(columns: names, allowed_constant_columns: allowed)
      end

      # Writes one `bulkWrite` of `$set`s for the documents in `results` whose masked copy differs, masking a copy
      # with the same plan #to_bulk_insert uses. Counterpart of #write_inserts; call #build_query first.
      #
      # @param io [#puts] where the mongosh script is written
      # @param results [Enumerable<Hash>] the documents named by `primary_key_values`, as #execute returns them
      # @param config [Exwiw::MongodbCollectionConfig] collection to mask
      # @param primary_key_values [Array<String>] the given primary keys (at most MaskUpdateRunner::CHUNK_SIZE)
      # @return [Array(Integer, Integer, Array<String>)] statements written, documents found, given keys with no document
      def write_mask_updates(io, results, config, primary_key_values)
        plan = mask_plan(config)
        docs = results.to_a
        ids = coerce_ids(primary_key_values)
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
        return [0, docs.size, missing] if operations.empty?

        io.puts "db.getCollection(#{js_literal(config.name)}).bulkWrite([\n#{operations.join(",\n")}\n]);"
        [1, docs.size, missing]
      end

      private def mask_target_names(plan, prefix = nil)
        own = (plan.masked_fields.map(&:first) + plan.faked_fields.map(&:first)).map { |n| [prefix, n].compact.join(".") }
        own + plan.embedded.flat_map { |e| mask_target_names(e.plan, [prefix, *e.prefix, e.last].compact.join(".")) }
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
          raise MaskUpdateRunner::Error, "cannot express #{value} in a mongosh script" unless value.finite?

          "Double(#{value})"
        when String then JSON.generate(value)
        when BSON::ObjectId then "ObjectId(\"#{value}\")"
        else raise MaskUpdateRunner::Error, "cannot express a #{value.class} value in a mongosh script"
        end
      end
    end
  end
end
