# frozen_string_literal: true

module Exwiw
  # Profile overlays (`<table>.<profile>.json`) against their base config. Each
  # operation works on the raw JSON hashes, before Serdes deserialization, where
  # `null` and an absent key are still distinguishable:
  #
  # - #merge: merges an overlay into its base config.
  # - #prune: drops the overlay entries the base no longer has (for tidy and check).
  # - #validate_unique_keys!: the keyed lists an overlay is matched against
  #   must have unique keys.
  #
  # How an attribute takes part is declared with a `merge:` option on its
  # Serdes declaration:
  #
  # - absent (default): replaced as a whole, including a nested object such
  #   as `batch_scope`.
  # - `:identity`: must equal the base value; it cannot be changed or nulled.
  # - `{ list: key_or_keys }`: entries are matched to base entries by the key
  #   attribute(s) and merged key by key; the base order is kept.
  # - `{ exclusive: group }`: setting one member of the group removes the
  #   other members.
  module ConfigOverlay
    module_function

    # Merges `overlay` into `base`. `null` in the overlay removes an optional key
    # (back to its default); on an identity, required or list attribute it is an error.
    #
    # @param klass [Class] TableConfig or MongodbCollectionConfig
    # @param base [Hash] the raw base config
    # @param overlay [Hash] the raw overlay config
    # @param owner [String] names the overlay in error messages
    # @return [Hash] the merged raw config, to be loaded with `klass.from`
    # @raise [ArgumentError] if the overlay cannot be merged
    def merge(klass, base, overlay, owner:)
      raise ArgumentError, "#{owner} must be a JSON object." unless overlay.is_a?(Hash)

      StrictKeys.validate!(klass, overlay, owner: owner)
      merge_record(klass, base, overlay, owner: owner, path: nil, keys: [])
    end

    # The overlay without the list entries (recursively) whose key the base no
    # longer has, for tidy and check.
    #
    # @return [Array(Hash, Array<String>)] the pruned overlay and the labels of
    #   the removed entries (e.g. `columns.legacy_col`)
    def prune(klass, base, overlay)
      removed = []
      [prune_record(klass, base, overlay, nil, removed), removed]
    end

    # @raise [ArgumentError] if a keyed list of the raw config `hash` has two
    #   entries with the same key
    def validate_unique_keys!(klass, hash, owner:, path: nil)
      return unless hash.is_a?(Hash)

      attributes(klass).each do |key, attr|
        next unless array_type?(attr.attr_type) && hash[key].is_a?(Array)

        key_names = list_keys!(klass, attr, owner: owner)
        element_klass = StrictKeys.serdes_class(attr.attr_type)
        seen = {}
        hash[key].each do |element|
          next unless element.is_a?(Hash)

          element_key = key_names.map { |name| element[name] }
          location = element_location(path, key, key_names, element_key)
          if seen.key?(element_key)
            raise ArgumentError,
                  "#{owner} has more than one #{location} entry; each entry of '#{key}' must be unique by " \
                  "#{key_names.join(', ')}."
          end

          seen[element_key] = true
          validate_unique_keys!(element_klass, element, owner: owner, path: location) if element_klass
        end
      end
    end

    # Every array attribute the merge walk can reach from `klass`, as
    # `[klass, attribute]` pairs.
    def reachable_array_attributes(klass, seen = [])
      return [] if seen.include?(klass)

      seen << klass
      attributes(klass).each_value.flat_map do |attr|
        next [] unless array_type?(attr.attr_type)

        element_klass = StrictKeys.serdes_class(attr.attr_type)
        nested = element_klass && list_keys(attr) ? reachable_array_attributes(element_klass, seen) : []
        [[klass, attr]] + nested
      end
    end

    # The list key(s) of an array attribute, or nil when it has no `list:` annotation.
    def list_keys(attr)
      kind = attr.options[:merge]
      return nil unless kind.is_a?(Hash) && kind.key?(:list)

      Array(kind[:list]).map(&:to_s)
    end

    private_class_method def merge_record(klass, base, overlay, owner:, path:, keys:)
      attrs = attributes(klass)
      result = base.dup

      overlay.each do |key, value|
        # A list element's key attributes already equal the base's: that is how it was matched.
        next if keys.include?(key)

        attr = attrs.fetch(key)
        location = path ? "#{path}.#{key}" : key

        if attr.options[:merge] == :identity
          next if value == base[key]

          raise ArgumentError,
                "#{owner}: '#{location}' identifies the config and cannot be changed or set to null " \
                "(base: #{base[key].inspect}, overlay: #{value.inspect})."
        end

        if array_type?(attr.attr_type)
          if value.nil?
            raise ArgumentError, "#{owner}: '#{location}' is a list and cannot be set to null."
          end

          result[key] = merge_list(klass, attr, base[key] || [], value, owner: owner, path: path, key: key)
        elsif value.nil?
          unless attr.attr_type.optional? || attr.options.key?(:default)
            raise ArgumentError, "#{owner}: '#{location}' is required and cannot be set to null."
          end

          result.delete(key)
        else
          result[key] = value
        end
      end

      exclusive_groups(attrs).each_value do |members|
        next if members.none? { |member| !overlay[member].nil? }

        (members - overlay.keys).each { |member| result.delete(member) }
      end

      result
    end

    private_class_method def merge_list(klass, attr, base_list, overlay_list, owner:, path:, key:)
      location = path ? "#{path}.#{key}" : key
      key_names = list_keys!(klass, attr, owner: owner)
      element_klass = StrictKeys.serdes_class(attr.attr_type)

      raise ArgumentError, "#{owner}: '#{location}' must be a list." unless overlay_list.is_a?(Array)

      base_index = {}
      base_list.each_with_index do |element, index|
        base_index[key_names.map { |name| element[name] }] = index if element.is_a?(Hash)
      end

      overlay_by_index = {}
      overlay_list.each_with_index do |element, position|
        unless element.is_a?(Hash)
          raise ArgumentError, "#{owner}: '#{location}[#{position}]' must be a JSON object."
        end

        element_key = key_names.map { |name| element[name] }
        element_path = element_location(path, key, key_names, element_key)
        index = base_index[element_key]
        if index.nil?
          raise ArgumentError,
                "#{owner}: '#{element_path}' does not exist in the base config; an overlay can only " \
                "change existing #{key} entries (matched by #{key_names.join(', ')})."
        end
        if overlay_by_index.key?(index)
          raise ArgumentError, "#{owner}: '#{element_path}' appears more than once in the overlay."
        end

        overlay_by_index[index] = [element, element_path]
      end

      base_list.each_with_index.map do |element, index|
        overlay_element, element_path = overlay_by_index[index]
        next element unless overlay_element

        merge_record(element_klass, element, overlay_element, owner: owner, path: element_path, keys: key_names)
      end
    end

    private_class_method def prune_record(klass, base, overlay, path, removed)
      return overlay unless base.is_a?(Hash) && overlay.is_a?(Hash)

      result = overlay.dup
      attributes(klass).each do |key, attr|
        next unless array_type?(attr.attr_type) && overlay[key].is_a?(Array)

        key_names = list_keys(attr)
        element_klass = StrictKeys.serdes_class(attr.attr_type)
        next if key_names.nil? || element_klass.nil?

        base_by_key = (base[key].is_a?(Array) ? base[key] : []).each_with_object({}) do |element, acc|
          acc[key_names.map { |name| element[name] }] = element if element.is_a?(Hash)
        end

        kept = overlay[key].filter_map do |element|
          next element unless element.is_a?(Hash)

          element_key = key_names.map { |name| element[name] }
          element_path = element_location(path, key, key_names, element_key)
          base_element = base_by_key[element_key]
          if base_element.nil?
            removed << element_path
            next
          end

          prune_record(element_klass, base_element, element, element_path, removed)
        end

        if kept.empty? && !overlay[key].empty?
          result.delete(key)
        else
          result[key] = kept
        end
      end
      result
    end

    # `columns.email` for a single key; `belongs_tos[table_name=users,foreign_key=user_id]` otherwise.
    private_class_method def element_location(path, key, key_names, element_key)
      prefix = path ? "#{path}.#{key}" : key
      if key_names.size == 1
        "#{prefix}.#{element_key.first}"
      else
        pairs = key_names.zip(element_key).reject { |_, value| value.nil? }
        "#{prefix}[#{pairs.map { |name, value| "#{name}=#{value}" }.join(',')}]"
      end
    end

    private_class_method def list_keys!(klass, attr, owner:)
      key_names = list_keys(attr)
      return key_names if key_names

      # Fail-safe: a list without a declared key cannot be merged element by element.
      raise ArgumentError,
            "#{owner}: #{klass}##{attr.name} is a list without a `merge: { list: ... }` annotation, " \
            "so an overlay cannot be merged into it."
    end

    private_class_method def exclusive_groups(attrs)
      attrs.each_with_object({}) do |(key, attr), groups|
        kind = attr.options[:merge]
        next unless kind.is_a?(Hash) && kind.key?(:exclusive)

        (groups[kind[:exclusive]] ||= []) << key
      end
    end

    private_class_method def attributes(klass)
      rename_strategy = klass.__send__(:_serde_rename_strategy)
      klass.__send__(:_serde_attrs).each_value.to_h { |attr| [attr.serialized_name(rename_strategy), attr] }
    end

    private_class_method def array_type?(type)
      type = type.base_type while type.is_a?(Serdes::OptionalType)
      type.is_a?(Serdes::ArrayType)
    end
  end
end
