# frozen_string_literal: true

module Exwiw
  # Configuration for a column's `replace_with_fake_data` masking mode
  # (see {RowTransformer}): the value is replaced with a fake value picked
  # deterministically from a faker-generated pool, keyed by a hash of the
  # `seed` column's value — so the same seed value always maps to the same
  # fake value, across runs and adapters.
  #
  # `seed` names a column of the same table, either bare (`"id"`) or
  # table-qualified (`"users.id"`). `type` selects the kind of fake value
  # (see RowTransformer::FAKE_TYPES). `locale` optionally sets the faker
  # locale used to build the pool (e.g. `"ja"`); nil uses faker's default.
  class FakeData
    include Serdes

    attribute :seed, String
    attribute :type, String
    attribute :locale, optional(String), skip_serializing_if_nil: true
  end
end
