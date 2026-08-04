# frozen_string_literal: true

module Exwiw
  # Opt-in config for batched extraction (see {BatchedExtraction} and the
  # `batch_scope` section of README.md): `table` is the scoped table whose
  # in-scope primary keys slice this table's extraction, `size` the ids per batch.
  class BatchScope
    include Serdes

    DEFAULT_SIZE = 1_000

    attribute :table, String
    attribute :size, optional(Integer), skip_serializing_if_nil: true
    attribute :comment, optional(String), skip_serializing_if_nil: true

    def batch_size
      size || DEFAULT_SIZE
    end
  end
end
