# frozen_string_literal: true

require "faraday"
require "json"
require "time"

module Indexmap
  module Pinger
    class IndexNow < Base
      def initialize(configuration: Indexmap.configuration, connection: nil)
        super(configuration: configuration)
        @connection = connection
      end

      def ping
        api_key = read_api_key
        unless api_key
          logger.debug("IndexNow API key is not configured.")
          return
        end

        entries = entries_to_ping
        if entries.empty?
          logger.debug("IndexNow: no URLs matched the current filter.")
          return
        end

        entries.each_slice(max_urls_per_request) do |batch|
          urls = batch.map(&:loc)

          if dry_run?
            logger.debug { "IndexNow dry-run: would ping #{urls.count} URLs." }
            next
          end

          submit_batch(api_key: api_key, urls: urls)
        end
      end

      def write_key_file
        key = index_now_configuration.key.to_s.strip
        return if key.empty?

        path = index_now_configuration.key_path(public_path: configuration.public_path)
        FileUtils.mkdir_p(path.dirname)
        File.write(path, "#{key}\n")
        path
      end

      private

      attr_reader :connection

      def index_now_configuration
        configuration.index_now
      end

      def sitemap_files
        files = super
        return files if files.one?

        child_files = files.reject { |file| File.basename(file) == configuration.index_filename }
        child_files.empty? ? files : child_files
      end

      def entries_to_ping
        cutoff = since_cutoff
        unless cutoff
          logger.debug("IndexNow: no cutoff provided, submitting all sitemap URLs.")
          return current_entries.values
        end

        logger.debug { "IndexNow: submitting sitemap URLs with lastmod >= #{cutoff.iso8601}." }

        current_entries.values.select do |entry|
          lastmod_after_cutoff?(entry, cutoff) || entry.lastmod.to_s.strip.empty?
        end
      end

      def current_entries
        sitemap_files.each_with_object({}) do |sitemap_file, entries|
          Parser.new(path: sitemap_file).entries.each do |entry|
            next if entry.loc.to_s.strip.empty?

            entries[entry.loc] = entry
          end
        end
      end

      def since_cutoff
        raw_value = ENV["SINCE"].to_s.strip
        return recent_cutoff if raw_value.empty?

        Time.iso8601(raw_value).utc
      rescue ArgumentError
        raise ArgumentError, "Invalid SINCE value: #{raw_value.inspect}. Use ISO 8601, e.g. 2026-04-18T10:30:00Z."
      end

      def recent_cutoff
        hours = ENV["INDEXNOW_RECENT_HOURS"].to_s.strip
        return if hours.empty?

        hours_ago = Integer(hours, exception: false)
        unless hours_ago&.positive?
          raise ArgumentError, "Invalid INDEXNOW_RECENT_HOURS value: #{hours.inspect}. Use a positive integer."
        end

        Time.now.utc - (hours_ago * 3600)
      end

      def lastmod_after_cutoff?(entry, cutoff)
        lastmod = entry_lastmod(entry)
        return false unless lastmod

        lastmod >= cutoff
      end

      def entry_lastmod(entry)
        return if entry.lastmod.to_s.strip.empty?

        Time.iso8601(entry.lastmod.to_s).utc
      rescue ArgumentError
        logger.debug { "IndexNow: skipping invalid sitemap lastmod #{entry.lastmod.inspect} for #{entry.loc}" }
        nil
      end

      def max_urls_per_request
        ENV.fetch("INDEXNOW_MAX_URLS_PER_REQUEST", index_now_configuration.max_urls_per_request).to_i
      end

      def submit_batch(api_key:, urls:)
        payload = {host: hostname, key: api_key, urlList: urls}
        response = index_now_connection.post("/indexnow") do |request|
          request.headers["Content-Type"] = "application/json"
          request.body = payload.to_json
        end

        if response.success?
          logger.debug { "Successfully pinged IndexNow with #{urls.count} URLs." }
          true
        else
          logger.debug { "Failed to ping IndexNow. Status: #{response.status}, Body: #{response.body}" }
          false
        end
      end

      def index_now_connection
        @index_now_connection ||= connection || Faraday.new(url: index_now_configuration.endpoint) do |faraday|
          faraday.request :json
        end
      end

      def dry_run?
        ENV["INDEXNOW_DRY_RUN"] == "1" || index_now_configuration.dry_run?
      end

      def read_api_key
        configured_key = index_now_configuration.key.to_s.strip
        return configured_key unless configured_key.empty?

        key_file = configuration.public_path.glob("*.txt").find do |file|
          filename = file.basename(".txt").to_s
          next unless filename.match?(/\A[a-zA-Z0-9-]{8,128}\z/)

          File.read(file).strip == filename
        end
        return nil unless key_file

        File.read(key_file).strip
      end
    end
  end
end
