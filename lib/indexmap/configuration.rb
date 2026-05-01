# frozen_string_literal: true

module Indexmap
  class Configuration
    VALID_FORMATS = %i[index single_file].freeze

    attr_writer :base_url, :entries, :format, :index_filename, :public_path, :sections, :store

    def initialize
      @format = :index
      @index_filename = "sitemap.xml"
      @after_create_callbacks = []
      @outputs = {}
    end

    def base_url
      resolve(@base_url)
    end

    def entries
      Array(resolve(@entries))
    end

    def format
      value = resolve(@format)
      value.nil? ? :index : value.to_sym
    end

    def google
      @google ||= GoogleConfiguration.new
    end

    def index_filename
      resolve(@index_filename)
    end

    def index_now
      @index_now ||= IndexNowConfiguration.new
    end

    def public_path
      value = resolve(@public_path)
      return Pathname("public") if value.nil?

      Pathname(value)
    end

    def sections
      Array(resolve(@sections))
    end

    def store
      resolve(@store)
    end

    def output(name)
      output = output_for(name)
      yield(output) if block_given?
      output
    end

    def output_for(name = :default)
      normalized_name = name.to_sym
      @outputs[normalized_name] ||= Output.new(name: normalized_name, configuration: self)
    end

    def after_create(&block)
      @after_create_callbacks << block if block
      @after_create_callbacks
    end

    def run_after_create_callbacks
      @after_create_callbacks.each(&:call)
    end

    def writer
      output_for(:default).writer
    end

    private

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end
  end
end
