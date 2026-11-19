# frozen_string_literal: true

module Exwiw
  # Profile overlays (`<table>.<profile>.json`) against their base config. Each
  # operation works on the raw JSON hashes, before Serdes deserialization, where
  # `null` and an absent key are still distinguishable:
  #
  # - #validate_unique_keys!: the keyed lists an overlay is matched against
  #   must have unique keys.
  #
  # An array attribute declares the key of its entries with a
  # `merge: { list: key_or_keys }` option on its Serdes declaration
  # (`columns` / `fields` by `name`, `belongs_tos` by
  # BelongsTo::IDENTITY_ATTRIBUTES).
  module ConfigOverlay
    module_function

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

    # The list key(s) of an array attribute, or nil when it has no `list:` annotation.
    def list_keys(attr)
      kind = attr.options[:merge]
      return nil unless kind.is_a?(Hash) && kind.key?(:list)

      Array(kind[:list]).map(&:to_s)
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
