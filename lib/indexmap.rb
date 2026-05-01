# frozen_string_literal: true

require "cgi"
require "date"
require "fileutils"
require "tmpdir"
require "time"

require_relative "indexmap/version"
require_relative "indexmap/artifact"
require_relative "indexmap/google_configuration"
require_relative "indexmap/index_now_configuration"
require_relative "indexmap/configuration"
require_relative "indexmap/entry"
require_relative "indexmap/output"
require_relative "indexmap/path"
require_relative "indexmap/parser"
require_relative "indexmap/pinger/base"
require_relative "indexmap/pinger/google"
require_relative "indexmap/pinger/index_now"
require_relative "indexmap/renderer"
require_relative "indexmap/section"
require_relative "indexmap/stores/file"
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

    def render(output_name = :default, configuration: self.configuration)
      Renderer.new(output: configuration.output_for(output_name)).render
    end

    def create(output_name = :default, configuration: self.configuration, run_after_create: false)
      output = configuration.output_for(output_name)
      artifacts = render(output_name, configuration: configuration)
      artifacts.each do |artifact|
        output.store.upload(
          filename: artifact.filename,
          body: artifact.body,
          content_type: artifact.content_type
        )
      end
      configuration.run_after_create_callbacks if run_after_create
      artifacts
    end

    def fetch(filename, output_name = :default, configuration: self.configuration)
      configuration.output_for(output_name).store.fetch(filename)
    end

    def fetch!(filename, output_name = :default, configuration: self.configuration)
      configuration.output_for(output_name).store.fetch!(filename)
    end
  end
end

require_relative "indexmap/railtie" if defined?(Rails::Railtie)
