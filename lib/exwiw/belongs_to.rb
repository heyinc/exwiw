# frozen_string_literal: true

module Exwiw
  class BelongsTo
    include Serdes

    attribute :foreign_key, String
    # Optional so an ignored, no-longer-resolvable relation (a stale
    # `belongs_to` whose target class is gone) can be recorded with no target
    # collection. A non-ignored belongs_to still requires it — enforced by the
    # owning config's validation (e.g. MongodbCollectionConfig#validate_belongs_tos!).
    attribute :table_name, optional(String), skip_serializing_if_nil: true
    # Set only for a polymorphic association. `foreign_type` is the name of the
    # column storing the type (e.g. `reviewable_type`), and `type_value` is the
    # value held in that column (e.g. `"Product"`). Both are nil for a
    # non-polymorphic belongs_to.
    attribute :foreign_type, optional(String), skip_serializing_if_nil: true
    attribute :type_value, optional(String), skip_serializing_if_nil: true
    # The field on the parent (`table_name`) that `foreign_key` actually points
    # at. nil means the parent's `primary_key` (the usual `_id`), so existing
    # configs behave exactly as before. Set it when the FK references a non-`_id`
    # parent field — e.g. Mongoid's `belongs_to :foo, primary_key: :uuid`, where
    # the child stores `foo.uuid` rather than `foo._id`.
    #
    # Only the MongodbAdapter consumes this (to stash and `$in`-match the right
    # parent field during foreign-key propagation); the SQL adapters ignore it,
    # since they join on the parent primary key. MongoidSchemaGenerator emits it
    # automatically from Mongoid's `belongs_to ..., primary_key:` (only when that
    # is non-`_id`); a value may also be hand-added, and either way it survives
    # regeneration (see TableConfig#merge / MongodbCollectionConfig#merge), so a
    # hand edit is not clobbered by re-introspection.
    attribute :references, optional(String), skip_serializing_if_nil: true
    # Mostly user-owned, and they survive regeneration (see TableConfig#merge /
    # MongodbCollectionConfig#merge). `ignore:true` drops the relation from
    # extraction once the config is loaded (see #reject_ignored_members!). The
    # schema generators emit them only for a relation they cannot express and so
    # auto-ignore — currently a cross-database belongs_to (see
    # SchemaGenerator#annotate_cross_database); a user may also add them by hand.
    attribute :comment, optional(String), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
    # Free-form tag recording *why* this relation is ignored (e.g.
    # "cross_database" for a relation crossing database boundaries,
    # "need_code_fix" for an application-side bug, "unsupported" for a shape
    # exwiw cannot express). exwiw never interprets it; purely informational and
    # preserved across regeneration like `comment`.
    attribute :ignore_type, optional(String), skip_serializing_if_nil: true

    def self.from_symbol_keys(hash)
      from(hash.transform_keys(&:to_s))
    end

    def polymorphic?
      !foreign_type.nil?
    end

    # Structural identity used to match a freshly generated belongs_to against a
    # user-maintained one during merge. `comment`/`ignore`/`references` are
    # intentionally excluded so a generated relation matches a hand-edited one
    # regardless of whether either carries a `references`, letting the merge
    # reconcile them (a hand-edited `references` wins over the generated one).
    def identity
      [table_name, foreign_key, foreign_type, type_value]
    end

    def to_hash
      super.compact
    end
  end
end
