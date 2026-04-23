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
          return {status: :skipped, reason: :missing_credentials}
        end

        results = sitemap_files.map { |sitemap_file| ping_sitemap(sitemap_file) }
        return {status: :skipped, reason: :no_sitemaps} if results.empty?

        summarize_results(results)
      end

      private

      attr_reader :credentials_builder

      def google_configuration
        configuration.google
      end

      def ping_sitemap(sitemap_file)
        sitemap_url = URI.join(host, File.basename(sitemap_file)).to_s

        unless authorized?
          logger.debug("Google Search Console does not have access to the site: #{root_domain}")
          return {
            status: :failed,
            reason: :unauthorized,
            property: property_identifier,
            root_domain: root_domain
          }
        end

        webmasters_service.submit_sitemap(property_identifier, sitemap_url)
        logger.debug { "Successfully pinged Google with sitemap: #{sitemap_url}" }
        {status: :submitted, sitemap_url: sitemap_url}
      rescue ::Google::Apis::ClientError => e
        logger.debug { "Failed to ping Google for #{sitemap_url}. Status: #{e.status_code}, Body: #{e.body}" }
        {
          status: :failed,
          reason: :client_error,
          sitemap_url: sitemap_url,
          status_code: e.status_code,
          body: e.body
        }
      end

      def authorized?
        @authorized ||= accessible_site_urls.include?(property_identifier)
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

      def summarize_results(results)
        submitted = results.select { |result| result[:status] == :submitted }
        failures = results.select { |result| result[:status] == :failed }

        return {status: :submitted, sitemap_count: submitted.count, submitted: submitted} if failures.empty?
        return {status: :failed, sitemap_count: 0, failures: failures} if submitted.empty?

        {
          status: :partial,
          sitemap_count: submitted.count,
          submitted: submitted,
          failures: failures
        }
      end

      def accessible_site_urls
        @accessible_site_urls ||= Array(webmasters_service.list_sites.site_entry).map(&:site_url)
      end
    end
  end
end
