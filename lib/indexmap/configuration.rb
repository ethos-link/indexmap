# frozen_string_literal: true

module Indexmap
  class Configuration
    VALID_FORMATS = %i[index single_file].freeze

    attr_accessor :atomic, :max_urls, :max_bytes

    attr_writer :base_url, :entries, :format, :index_filename, :sections, :storage

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
      value = resolve(@entries)
      value.is_a?(Enumerable) ? value : Array(value)
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

    def robots
      @robots ||= Robots.new(configuration: self)
    end

    def storage
      resolve(@storage) || Storage::Filesystem.new(path: "public", public_url: base_url)
    end

    def sections
      Array(resolve(@sections))
    end

    def output_names
      [:default, *@outputs.keys].uniq
    end

    def output(name)
      output = output_for(name)
      yield(output) if block_given?
      output
    end

    def output_for(name = :default)
      normalized_name = name.to_sym
      @outputs[normalized_name] ||= Output.new(configuration: self)
    end

    def after_create(&block)
      raise ArgumentError, "after_create requires a block" unless block

      @after_create_callbacks << block
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
