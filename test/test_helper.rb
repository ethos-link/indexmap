# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  add_filter "/test/"
end

require "minitest/autorun"
require "tmpdir"
require "date"
require "webmock/minitest"

require "indexmap"
