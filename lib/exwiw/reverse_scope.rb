# frozen_string_literal: true

module Exwiw
  # One referencer arm of a {ReverseScope}: the referencing table and the column
  # on it that points at the reverse-scoped table's primary key.
  #
  # `column` is given explicitly so a *non-default* foreign key (e.g.
  # `business_entity_customers.kantan_yoyaku_user_id`, or `organization_admins.id`
  # which itself references `users.id`) can be projected — and even a column with
  # no declared `belongs_to` edge can be enumerated.
  class ReverseScopeVia
    include Serdes

    attribute :table, String
    attribute :column, String
  end

  # Opt-in configuration for *multi-referencer* reverse scoping
  # (see {QueryAstBuilder#build_referenced_by_clause}).
  #
  # A global-identity table such as `users` carries no scope/tenant column and
  # has no `belongs_to` path of its own to the dump target; many tenant-owned
  # tables instead point *at* it. The automatic single-referencer reverse
  # extraction only narrows a table referenced by exactly one constrained child
  # — with two or more referencers it falls back to a full dump. `reverse_scope`
  # lets the schema author enumerate the referencers whose own (already-scoped)
  # extraction queries should be UNION'd into the id set this table is
  # constrained to:
  #
  #   <table>.<pk> IN (
  #     SELECT <ref1>.<col1> FROM <ref1> <ref1 scope> WHERE <col1> IS NOT NULL
  #     UNION SELECT <ref2>.<col2> FROM <ref2> <ref2 scope> WHERE <col2> IS NOT NULL
  #     UNION ...
  #   )
  #
  # It is deliberately explicit — never inferred or emitted by the schema
  # generators, and preserved across regeneration like the other user-owned
  # config (see {TableConfig#merge}). Only referencers that are themselves scoped
  # belong in `via`: an unconstrained referencer would project every row's id and
  # union the whole table back, defeating the prune (such an arm is skipped with
  # a warning rather than silently widening the dump).
  class ReverseScope
    include Serdes

    attribute :via, array(ReverseScopeVia), default: []
  end
end
