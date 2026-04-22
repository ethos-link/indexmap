# frozen_string_literal: true

require "google/apis/searchconsole_v1"
require "googleauth"
require "json"
require "stringio"

module Indexmap
  module Pinger
    class Google < Base
      def initialize(configuration: Indexmap.configuration, service: nil, credentials_builder: nil)
        super(configuration: configuration)
        @service = service
        @credentials_builder = credentials_builder
      end

      def ping
        if google_configuration.credentials.to_s.strip.empty?
          logger.debug("Google sitemap credentials not configured.")
          return
        end

        super
      end

      private

      attr_reader :credentials_builder

      def google_configuration
        configuration.google
      end

      def ping_sitemap(sitemap_file)
        sitemap_url = URI.join(host, File.basename(sitemap_file)).to_s

        unless authorized?
          logger.error("Google Search Console does not have access to the site: #{root_domain}")
          return
        end

        webmasters_service.submit_sitemap(property_identifier, sitemap_url)
        logger.debug { "Successfully pinged Google with sitemap: #{sitemap_url}" }
      rescue ::Google::Apis::ClientError => e
        logger.debug { "Failed to ping Google for #{sitemap_url}. Status: #{e.status_code}, Body: #{e.body}" }
      end

      def authorized?
        webmasters_service.list_sites.site_entry.any? { |site| site.site_url.include?(root_domain) }
      end

      def property_identifier
        property = google_configuration.property
        property.to_s.strip.empty? ? "sc-domain:#{root_domain}" : property
      end

      def webmasters_service
        @webmasters_service ||= begin
          service = @service || ::Google::Apis::SearchconsoleV1::SearchConsoleService.new
          service.authorization = authorizer
          service
        end
      end

      def authorizer
        json_key = JSON.parse(google_configuration.credentials).to_json
        scope = "https://www.googleapis.com/auth/webmasters"

        return credentials_builder.call(credentials: json_key, scope: scope) if credentials_builder

        ::Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(json_key),
          scope: scope
        )
      end
    end
  end
end
