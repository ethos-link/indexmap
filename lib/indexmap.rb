# frozen_string_literal: true

require "cgi"
require "date"
require "fileutils"
require "pathname"
require "time"

require_relative "indexmap/version"
require_relative "indexmap/google_configuration"
require_relative "indexmap/index_now_configuration"
require_relative "indexmap/configuration"
require_relative "indexmap/entry"
require_relative "indexmap/path"
require_relative "indexmap/parser"
require_relative "indexmap/pinger/base"
require_relative "indexmap/pinger/google"
require_relative "indexmap/pinger/index_now"
require_relative "indexmap/section"
require_relative "indexmap/task_runner"
require_relative "indexmap/validator"
require_relative "indexmap/writer"

module Indexmap
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class ValidationError < Error; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset!
      @configuration = Configuration.new
    end
  end
end

require_relative "indexmap/railtie" if defined?(Rails::Railtie)
