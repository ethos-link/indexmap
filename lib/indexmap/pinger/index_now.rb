# frozen_string_literal: true

require "faraday"
require "json"
require "securerandom"
require "time"

module Indexmap
  module Pinger
    class IndexNow < Base
      KEY_FORMAT = /\A[a-f0-9]{32}\z/

      def initialize(configuration: Indexmap.configuration, storage: nil, connection: nil)
        super(configuration: configuration, storage: storage)
        @connection = connection
      end

      def ping
        api_key = read_api_key
        unless api_key
          logger.debug("IndexNow API key is not configured.")
          return {status: :skipped, reason: :missing_key}
        end

        batch_size = max_urls_per_request
        entries = entries_to_ping
        results = entries.each_slice(batch_size).map.with_index(1) do |batch, number|
          urls = batch.map(&:loc)

          if dry_run?
            logger.debug { "IndexNow dry-run: would ping #{urls.count} URLs." }
            next({status: :dry_run, url_count: urls.count})
          end

          attempts = index_now_configuration.max_attempts || 1
          max_wait = index_now_configuration.max_wait || 30
          unless attempts.is_a?(Integer) && (1..5).cover?(attempts) && max_wait.is_a?(Numeric) && (0..60).cover?(max_wait)
            raise ConfigurationError, "IndexNow retries require 1..5 attempts and 0..60 seconds max_wait"
          end
          result = nil
          attempts.times do |attempt|
            yield({event: :attempt_started, batch: number, attempt: attempt + 1, urls: urls}) if block_given?
            result = submit_batch(api_key: api_key, urls: urls)
            yield(result.merge(event: :attempt_finished, batch: number, attempt: attempt + 1, urls: urls)) if block_given?
            retryable = result[:reason] == :unknown_delivery || [429, 500, 502, 503, 504].include?(result[:status_code])
            break unless retryable && attempt + 1 < attempts

            delay = result[:retry_after] || [2**attempt + rand, max_wait].min
            break if delay > max_wait

            sleep(delay)
          end
          result
        end

        return {status: :skipped, reason: :no_urls} if results.empty?

        summarize_results(results)
      end

      def plan
        return enum_for(:plan) unless block_given?

        cutoff = since_cutoff
        batch_size = max_urls_per_request
        missing_key = read_api_key.nil?
        selected_count = 0
        each_selection(cutoff: cutoff) do |entry, reason, selected|
          selected_count += 1 if selected
          yield({
            loc: entry.loc,
            lastmod: entry.lastmod,
            source_sitemap: entry.source_sitemap,
            index_filename: configuration.index_filename,
            cutoff: cutoff&.iso8601,
            reason: reason,
            selected: selected,
            batch: selected ? ((selected_count - 1) / batch_size) + 1 : nil,
            missing_key: missing_key
          })
        end
      end

      def write_key_file(key: index_now_configuration.key, filename: nil)
        key = normalized_configured_key(key)
        return if key.empty?

        filename ||= index_now_configuration.key_filename(key: key)
        return filename if valid_key_file?(filename)

        storage.write(filename, key, content_type: "text/plain")
        filename
      end

      def ensure_key_file
        configured_key = normalized_configured_key(index_now_configuration.key)
        return write_key_file(key: configured_key) unless configured_key.empty?

        existing_path = existing_key_file
        return existing_path if existing_path

        key = generated_key
        write_key_file(key: key, filename: "#{key}.txt")
      end

      private

      attr_reader :connection

      def index_now_configuration
        configuration.index_now
      end

      def entries_to_ping
        enum_for(:each_selection, cutoff: since_cutoff).lazy.filter_map do |entry, _reason, selected|
          entry if selected
        end.eager
      end

      def each_selection(cutoff:)
        sitemap_files.each do |filename|
          validator = Validator.new(configuration: configuration, filename: filename, storage: storage)
          validator.each_entry do |entry|
            reason = if cutoff.nil?
              :all
            elsif entry.lastmod.to_s.strip.empty?
              :missing_lastmod
            elsif lastmod_after_cutoff?(entry, cutoff)
              :recent
            else
              :before_cutoff
            end
            yield entry, reason, reason != :before_cutoff
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
        if entry.lastmod.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          Date.iso8601(entry.lastmod) >= cutoff.to_date
        else
          Time.iso8601(entry.lastmod).utc >= cutoff
        end
      end

      def max_urls_per_request
        value = ENV.fetch("INDEXNOW_MAX_URLS_PER_REQUEST") { index_now_configuration.max_urls_per_request }
        size = Integer(value.to_s, 10, exception: false)
        unless size && (1..10_000).cover?(size)
          raise ConfigurationError, "IndexNow batch size must be an integer from 1 through 10,000"
        end
        size
      end

      def submit_batch(api_key:, urls:)
        payload = {host: hostname, key: api_key, urlList: urls}
        location = key_location(api_key: api_key)
        payload[:keyLocation] = location if location

        response = index_now_connection.post("/indexnow") do |request|
          request.headers["Content-Type"] = "application/json"
          request.body = JSON.generate(payload)
        end

        if response.success?
          logger.debug { "Successfully pinged IndexNow with #{urls.count} URLs." }
          {status: :submitted, url_count: urls.count, status_code: response.status,
           receipt: (response.status == 202) ? :validation_pending : :received}
        else
          logger.debug { "Failed to ping IndexNow. Status: #{response.status}" }
          {status: :failed, url_count: urls.count, status_code: response.status,
           body: response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace).gsub(api_key, "[FILTERED]").slice(0, 1024),
           retry_after: retry_after(response.headers["retry-after"])}
        end
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed
        {status: :failed, url_count: urls.count, reason: :unknown_delivery}
      end

      def retry_after(value)
        return if value.to_s.empty?

        seconds = Integer(value.to_s, exception: false)
        seconds ||= Time.httpdate(value).utc - Time.now.utc
        [seconds, 0].max
      rescue ArgumentError
        nil
      end

      def index_now_connection
        @index_now_connection ||= connection || Faraday.new(url: index_now_configuration.endpoint) do |faraday|
          faraday.options.open_timeout = 5
          faraday.options.timeout = 20
          faraday.request :json
        end
      end

      def dry_run?
        ENV["INDEXNOW_DRY_RUN"] == "1" || index_now_configuration.dry_run?
      end

      def read_api_key
        configured_key = normalized_configured_key(index_now_configuration.key)
        return configured_key unless configured_key.empty?

        storage.read(existing_key_file) if existing_key_file
      end

      def existing_key_file
        configured_filename = index_now_configuration.key_filename
        return configured_filename if valid_key_file?(configured_filename)

        storage.list(suffix: ".txt").find { |filename| valid_key_file?(filename) }
      end

      def key_location(api_key:)
        filename = index_now_configuration.key_filename(key: api_key) || existing_key_file
        return unless filename

        storage.public_url(filename)
      rescue ArgumentError
        nil
      end

      def valid_key_file?(filename)
        return false unless filename && storage.exist?(filename)

        key = File.basename(filename, ".txt").to_s
        return false unless key.match?(KEY_FORMAT)

        storage.read(filename) == key
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
