# frozen_string_literal: true

require "mkmf"

# Compiled to lib/exwiw/ext_json_native.{so,bundle}. The name is distinct from
# the `ext_json.rb` shim so `require "exwiw/ext_json_native"` does not collide
# with `require_relative "exwiw/ext_json"`.
create_makefile("exwiw/ext_json_native")
