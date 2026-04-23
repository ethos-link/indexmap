# frozen_string_literal: true

require "faraday"
require "json"
require "securerandom"
require "time"

module Indexmap
  module Pinger
    class IndexNow < Base
      KEY_FORMAT = /\A[a-f0-9]{32}\z/

      def initialize(configuration: Indexmap.configuration, connection: nil)
        super(configuration: configuration)
        @connection = connection
      end

      def ping
        api_key = read_api_key
        unless api_key
          logger.debug("IndexNow API key is not configured.")
          return {status: :skipped, reason: :missing_key}
        end

        entries = entries_to_ping
        if entries.empty?
          logger.debug("IndexNow: no URLs matched the current filter.")
          return {status: :skipped, reason: :no_urls}
        end

        results = entries.each_slice(max_urls_per_request).map do |batch|
          urls = batch.map(&:loc)

          if dry_run?
            logger.debug { "IndexNow dry-run: would ping #{urls.count} URLs." }
            next({status: :dry_run, url_count: urls.count})
          end

          submit_batch(api_key: api_key, urls: urls)
        end

        summarize_results(results)
      end

      def write_key_file(key: index_now_configuration.key, path: nil)
        key = normalized_configured_key(key)
        return if key.empty?

        path ||= index_now_configuration.key_path(public_path: configuration.public_path, key: key)
        FileUtils.mkdir_p(path.dirname)
        File.write(path, key)
        path
      end

      def ensure_key_file
        configured_key = normalized_configured_key(index_now_configuration.key)
        return write_key_file(key: configured_key) unless configured_key.empty?

        existing_path = existing_key_file
        return existing_path if existing_path

        key = generated_key
        write_key_file(key: key, path: configuration.public_path.join("#{key}.txt"))
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
        location = key_location(api_key: api_key)
        payload[:keyLocation] = location if location

        response = index_now_connection.post("/indexnow") do |request|
          request.headers["Content-Type"] = "application/json"
          request.body = payload.to_json
        end

        if response.success?
          logger.debug { "Successfully pinged IndexNow with #{urls.count} URLs." }
          {status: :submitted, url_count: urls.count}
        else
          logger.debug { "Failed to ping IndexNow. Status: #{response.status}, Body: #{response.body}" }
          {status: :failed, url_count: urls.count, status_code: response.status, body: response.body}
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
        configured_key = normalized_configured_key(index_now_configuration.key)
        return configured_key unless configured_key.empty?

        existing_key_file&.read
      end

      def existing_key_file
        configured_path = index_now_configuration.key_path(public_path: configuration.public_path)
        return configured_path if valid_key_file?(configured_path)

        configuration.public_path.glob("*.txt").sort.find { |file| valid_key_file?(file) }
      end

      def key_location(api_key:)
        path = index_now_configuration.key_path(public_path: configuration.public_path, key: api_key) || existing_key_file
        return unless path

        public_path = configuration.public_path.expand_path
        key_path = path.expand_path
        relative_path = key_path.relative_path_from(public_path)

        URI.join("#{host}/", relative_path.to_s).to_s
      rescue ArgumentError
        nil
      end

      def valid_key_file?(path)
        return false unless path&.file?

        filename = path.basename(".txt").to_s
        return false unless filename.match?(KEY_FORMAT)

        path.read == filename
      end

      def generated_key
        SecureRandom.hex(16)
      end

      def normalized_configured_key(value)
        key = value.to_s.strip
        return key if key.empty? || key.match?(KEY_FORMAT)

        raise ConfigurationError, "IndexNow key must be a 32-character lowercase hexadecimal string"
      end

      def summarize_results(results)
        dry_runs = results.select { |result| result[:status] == :dry_run }
        submitted = results.select { |result| result[:status] == :submitted }
        failures = results.select { |result| result[:status] == :failed }

        if dry_runs.any?
          return {
            status: :dry_run,
            url_count: dry_runs.sum { |result| result[:url_count] },
            batch_count: dry_runs.count
          }
        end

        if failures.empty?
          return {
            status: :submitted,
            url_count: submitted.sum { |result| result[:url_count] },
            batch_count: submitted.count
          }
        end

        if submitted.empty?
          return {
            status: :failed,
            url_count: 0,
            batch_count: 0,
            failures: failures
          }
        end

        {
          status: :partial,
          url_count: submitted.sum { |result| result[:url_count] },
          batch_count: submitted.count,
          failures: failures
        }
      end
    end
  end
end
