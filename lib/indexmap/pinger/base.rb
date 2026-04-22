# frozen_string_literal: true

require "logger"
require "uri"

module Indexmap
  module Pinger
    class Base
      def self.ping(...)
        new(...).ping
      end

      def initialize(configuration: Indexmap.configuration)
        @configuration = configuration
      end

      def ping
        sitemap_files.each do |sitemap_file|
          ping_sitemap(sitemap_file)
        end
      end

      def logger
        @logger ||= if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger
        else
          Logger.new($stderr).tap do |logger|
            logger.level = Logger::WARN
          end
        end
      end

      private

      attr_reader :configuration

      def host
        configuration.base_url
      end

      def hostname
        URI.parse(host).host
      end

      def root_domain
        hostname.sub(/\Awww\./, "")
      end

      def sitemap_files
        Dir.glob(configuration.public_path.join("sitemap*.xml")).sort
      end

      def ping_sitemap(_sitemap_file)
        raise NotImplementedError
      end
    end
  end
end
