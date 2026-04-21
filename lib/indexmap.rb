# frozen_string_literal: true

require "cgi"
require "date"
require "fileutils"
require "pathname"
require "time"

require_relative "indexmap/version"
require_relative "indexmap/configuration"
require_relative "indexmap/entry"
require_relative "indexmap/section"
require_relative "indexmap/task_runner"
require_relative "indexmap/writer"

module Indexmap
  class Error < StandardError; end

  class ConfigurationError < Error; end

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
