# frozen_string_literal: true

module Exwiw
  # Raised when a schema config JSON carries a key that no declared attribute
  # accepts. A subclass of ArgumentError so existing "invalid config" handling
  # (and specs) that rescue ArgumentError keep working.
  UnknownConfigKeyError = Class.new(ArgumentError)

  # Strict key validation for the schema config JSON.
  #
  # Serdes deserialization is lenient: a key that matches no declared attribute
  # is silently dropped. For hand-maintained schema configs that turns a typo
  # (`reverse_scop`) — or a key another adapter supports but this one does not
  # (`raw_sql` on a MongoDB field) — into a silent no-op: the config loads, the
  # dump runs, and the requested masking/scoping simply never happens.
  # {TableConfig.from} / {MongodbCollectionConfig.from} therefore validate the
  # raw hash against the declared attributes before deserializing, recursing
  # into nested config objects (belongs_tos, columns/fields, reverse_scope,
  # embedded_in, replace_with_fake_data).
  #
  # Free-form annotations do not need an escape hatch: `comment` is a declared
  # (documentation-only) attribute on the table/collection configs and their
  # belongs_to/column/field entries, so it always passes.
  module StrictKeys
    module_function

    # Validate `hash` (a raw config hash, string- or symbol-keyed) against the
    # attributes declared on the Serdes class `klass`, recursing into nested
    # Serdes-typed attributes. `owner` names the config for the error message
    # (e.g. "table 'users'"); `path` locates a nested entry within it (e.g.
    # "belongs_tos[0]"). No-op for non-Hash input — Serdes' own type errors
    # cover malformed values.
    def validate!(klass, hash, owner:, path: nil)
      return unless hash.is_a?(Hash)

      attributes = klass.__send__(:_serde_attrs)
      rename_strategy = klass.__send__(:_serde_rename_strategy)
      allowed = attributes.each_value.to_h { |attr| [attr.serialized_name(rename_strategy), attr] }

      unknown = hash.keys.map(&:to_s) - allowed.keys
      unless unknown.empty?
        location = path ? " (in #{path})" : ""
        raise UnknownConfigKeyError,
              "Unknown key#{'s' if unknown.size > 1} #{unknown.map { |key| "'#{key}'" }.join(', ')} " \
              "in #{owner}#{location}. Allowed keys: #{allowed.keys.sort.join(', ')}. " \
              "Unknown keys are rejected because they would otherwise be silently ignored " \
              "(hiding typos and keys this adapter does not support); remove or rename the key, " \
              "or use `comment` for free-form notes."
      end

      allowed.each do |key, attr|
        nested_klass = serdes_class(attr.attr_type)
        next if nested_klass.nil?

        value = hash.key?(key) ? hash[key] : hash[key.to_sym]
        nested_path = path ? "#{path}.#{key}" : key
        case value
        when Hash
          validate!(nested_klass, value, owner: owner, path: nested_path)
        when Array
          value.each_with_index do |element, index|
            validate!(nested_klass, element, owner: owner, path: "#{nested_path}[#{index}]") if element.is_a?(Hash)
          end
        end
      end
    end

    # The Serdes-including class a (possibly optional/array-wrapped) attribute
    # type deserializes into, or nil for scalar types.
    def serdes_class(type)
      case type
      when Serdes::OptionalType then serdes_class(type.base_type)
      when Serdes::ArrayType then serdes_class(type.element_type)
      when Serdes::ConcreteType then serdes_class(type.exact_type)
      when Class then type if type.include?(Serdes)
      end
    end
  end
end
