# frozen_string_literal: true

require "test_helper"
require "indexmap/tasks"

class IndexmapPingerIndexNowTest < Minitest::Test
  VALID_KEY = "1234567890abcdef1234567890abcdef"

  def test_writes_key_file_from_configuration
    storage = Indexmap::Storage::Memory.new
    configuration = configuration_with(storage: storage)
    configuration.index_now.key = VALID_KEY

    filename = Indexmap::Pinger::IndexNow.new(configuration: configuration).write_key_file

    assert_equal "#{VALID_KEY}.txt", filename
    assert_equal VALID_KEY, storage.read(filename)
  end

  def test_does_not_rewrite_existing_valid_key_file
    storage = Indexmap::Storage::Memory.new
    storage.write("#{VALID_KEY}.txt", VALID_KEY, content_type: "text/plain")
    configuration = configuration_with(storage: storage)
    configuration.index_now.key = VALID_KEY

    result = Indexmap::Pinger::IndexNow.new(configuration: configuration).write_key_file

    assert_equal "#{VALID_KEY}.txt", result
    assert_equal VALID_KEY, storage.read(result)
  end

  def test_ensure_key_file_generates_a_key_when_configuration_is_missing
    storage = Indexmap::Storage::Memory.new
    configuration = configuration_with(storage: storage)

    filename = Indexmap::Pinger::IndexNow.new(configuration: configuration).ensure_key_file

    assert_match(/\A[a-f0-9]{32}\.txt\z/, filename)
    assert_equal filename.delete_suffix(".txt"), storage.read(filename)
  end

  def test_pings_using_existing_key_file_when_key_is_not_configured
    storage = sitemap_storage
    storage.write("#{VALID_KEY}.txt", VALID_KEY, content_type: "text/plain")
    configuration = configuration_with(storage: storage)

    indexnow_url = "https://api.indexnow.org/indexnow"
    stub_request(:post, indexnow_url).to_return(status: 200, body: "", headers: {})

    result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

    assert_requested(:post, indexnow_url, times: 1) do |request|
      payload = JSON.parse(request.body)
      assert_equal VALID_KEY, payload.fetch("key")
      assert_equal "https://www.example.com/#{VALID_KEY}.txt", payload.fetch("keyLocation")
    end
    assert_equal :submitted, result[:status]
    assert_equal 2, result[:url_count]
    assert_equal 1, result[:batch_count]
  end

  def test_ignores_existing_key_file_with_trailing_newline
    storage = Indexmap::Storage::Memory.new
    storage.write("#{VALID_KEY}.txt", "#{VALID_KEY}\n", content_type: "text/plain")
    configuration = configuration_with(storage: storage)

    filename = Indexmap::Pinger::IndexNow.new(configuration: configuration).ensure_key_file

    refute_equal "#{VALID_KEY}.txt", filename
    assert_match(/\A[a-f0-9]{32}\.txt\z/, filename)
    assert_equal filename.delete_suffix(".txt"), storage.read(filename)
  end

  def test_pings_all_sitemap_urls_when_no_cutoff_is_provided
    storage = sitemap_storage
    storage.write("sitemap-stale.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://www.example.com/retired</loc></url>
      </urlset>
    XML
    configuration = configuration_with(storage: storage)
    configuration.index_now.key = VALID_KEY

    indexnow_url = "https://api.indexnow.org/indexnow"
    stub_request(:post, indexnow_url).to_return(status: 200, body: "", headers: {})

    result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

    assert_requested(:post, indexnow_url, times: 1) do |request|
      payload = JSON.parse(request.body)
      assert_equal [
        "https://www.example.com/pages/features",
        "https://www.example.com/insights/us/restaurants/overview"
      ].sort, payload.fetch("urlList").sort
      assert_equal "https://www.example.com/#{VALID_KEY}.txt", payload.fetch("keyLocation")
    end
    assert_equal :submitted, result[:status]
    assert_equal 2, result[:url_count]
    assert_equal 1, result[:batch_count]
  end

  def test_pings_sitemap_urls_from_directory_storage_keys
    storage = Indexmap::Storage::Memory.new(public_url: "https://www.example.com")
    storage.write("sitemaps/sitemap.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://www.example.com/sitemaps/sitemap-marketing.xml</loc></sitemap>
      </sitemapindex>
    XML
    storage.write("sitemaps/sitemap-marketing.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://www.example.com/pages/features</loc></url>
      </urlset>
    XML
    configuration = configuration_with(storage: storage, index_filename: "sitemaps/sitemap.xml")
    configuration.index_now.key = VALID_KEY

    indexnow_url = "https://api.indexnow.org/indexnow"
    stub_request(:post, indexnow_url).to_return(status: 200, body: "", headers: {})

    result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

    assert_requested(:post, indexnow_url, times: 1) do |request|
      payload = JSON.parse(request.body)
      assert_equal ["https://www.example.com/pages/features"], payload.fetch("urlList")
    end
    assert_equal :submitted, result[:status]
    assert_equal 1, result[:url_count]
  end

  def test_pings_only_sitemap_urls_newer_than_since
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY

    indexnow_url = "https://api.indexnow.org/indexnow"
    stub_request(:post, indexnow_url).to_return(status: 200, body: "", headers: {})

    with_env("SINCE" => "2026-04-15T00:00:00Z") do
      result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

      assert_equal :submitted, result[:status]
      assert_equal 1, result[:url_count]
      assert_equal 1, result[:batch_count]
    end

    assert_requested(:post, indexnow_url, times: 1) do |request|
      payload = JSON.parse(request.body)
      assert_equal ["https://www.example.com/pages/features"], payload.fetch("urlList")
    end
  end

  def test_skips_indexnow_ping_when_key_is_missing
    configuration = configuration_with(storage: sitemap_storage)

    result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

    assert_equal({status: :skipped, reason: :missing_key}, result)
  end

  def test_reports_indexnow_dry_run
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY

    with_env("INDEXNOW_DRY_RUN" => "1") do
      result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

      assert_equal :dry_run, result[:status]
      assert_equal 2, result[:url_count]
      assert_equal 1, result[:batch_count]
    end
  end

  def test_reports_failed_indexnow_submission
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY

    indexnow_url = "https://api.indexnow.org/indexnow"
    stub_request(:post, indexnow_url).to_return(status: 500, body: "boom", headers: {})

    result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

    assert_equal :failed, result[:status]
    assert_equal 1, result[:failures].count
    assert_equal 500, result[:failures].first[:status_code]
  end

  def test_rejects_invalid_configured_key
    configuration = configuration_with
    configuration.index_now.key = "test-key"

    error = assert_raises(Indexmap::ConfigurationError) do
      Indexmap::Pinger::IndexNow.new(configuration: configuration).ping
    end

    assert_equal "IndexNow key must be a 32-character lowercase hexadecimal string", error.message
  end

  def test_reuses_existing_key_file_deterministically
    storage = Indexmap::Storage::Memory.new
    storage.write("ffffffffffffffffffffffffffffffff.txt", "ffffffffffffffffffffffffffffffff")
    storage.write("00000000000000000000000000000000.txt", "00000000000000000000000000000000")
    configuration = configuration_with(storage: storage)

    filename = Indexmap::Pinger::IndexNow.new(configuration: configuration).ensure_key_file

    assert_equal "00000000000000000000000000000000.txt", filename
  end

  def test_date_only_lastmods_include_the_cutoff_day
    configuration = configuration_with(storage: sitemap_storage(
      marketing_lastmod: "2026-04-18", insights_lastmod: "2026-04-17"
    ))
    configuration.index_now.key = VALID_KEY
    configuration.index_now.dry_run = true

    with_env("SINCE" => "2026-04-18T23:59:59Z") do
      assert_equal 1, Indexmap::Pinger::IndexNow.new(configuration: configuration).ping.fetch(:url_count)
    end
  end

  def test_rejects_invalid_batch_sizes_before_sending
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY
    %w[0 -1 invalid 1.5 10001].each do |value|
      with_env("INDEXNOW_MAX_URLS_PER_REQUEST" => value) do
        assert_raises(Indexmap::ConfigurationError) do
          Indexmap::Pinger::IndexNow.new(configuration: configuration).ping
        end
      end
    end
    assert_not_requested(:post, "https://api.indexnow.org/indexnow")
  end

  def test_invalid_since_does_not_fall_back_to_recent_hours
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY
    with_env("SINCE" => "invalid", "INDEXNOW_RECENT_HOURS" => "24") do
      assert_raises(ArgumentError) { Indexmap::Pinger::IndexNow.new(configuration: configuration).ping }
    end
  end

  def test_plan_without_a_key_reports_exact_selection_and_exclusions
    configuration = configuration_with(storage: sitemap_storage)
    with_env("SINCE" => "2026-04-15T00:00:00Z") do
      rows = Indexmap::Pinger::IndexNow.new(configuration: configuration).plan.to_a
      assert_equal 2, rows.size
      selected = rows.find { |row| row.fetch(:selected) }
      assert_equal "https://www.example.com/pages/features", selected.fetch(:loc)
      assert_equal "sitemap-marketing.xml", selected.fetch(:source_sitemap)
      assert_equal :recent, selected.fetch(:reason)
      assert_equal 1, selected.fetch(:batch)
      assert selected.fetch(:missing_key)
      assert_equal :before_cutoff, rows.find { |row| !row.fetch(:selected) }.fetch(:reason)
    end
    assert_not_requested(:post, "https://api.indexnow.org/indexnow")
  end

  def test_plan_matches_submitted_batches_and_explains_undated_entries
    configuration = configuration_with(storage: sitemap_storage(marketing_lastmod: ""))
    configuration.index_now.key = VALID_KEY
    configuration.index_now.max_urls_per_request = 1
    stub_request(:post, "https://api.indexnow.org/indexnow").to_return(status: 200)
    with_env("SINCE" => "2026-04-15T00:00:00Z") do
      pinger = Indexmap::Pinger::IndexNow.new(configuration: configuration)
      rows = pinger.plan.select { |row| row.fetch(:selected) }
      assert_equal :missing_lastmod, rows.first.fetch(:reason)
      events = []
      pinger.ping { |event| events << event }
      assert_equal rows.map { |row| row.fetch(:loc) }, events.select { |event| event[:event] == :attempt_started }.flat_map { |event| event[:urls] }
      refute_includes events.to_json, VALID_KEY
    end
  end

  def test_transport_failure_preserves_earlier_receipts_and_reports_uncertainty
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY
    configuration.index_now.max_urls_per_request = 1
    stub_request(:post, "https://api.indexnow.org/indexnow")
      .to_return(status: 202).then.to_timeout
    events = []
    result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping { |event| events << event }
    assert_equal :partial, result.fetch(:status)
    assert_equal 1, result.fetch(:url_count)
    assert_equal :unknown_delivery, result.fetch(:failures).first.fetch(:reason)
    receipts = events.select { |event| event[:event] == :attempt_finished }
    assert_equal 202, receipts.first.fetch(:status_code)
    assert_equal :validation_pending, receipts.first.fetch(:receipt)
    assert_equal :unknown_delivery, receipts.last.fetch(:reason)
  end

  def test_plan_task_exports_json_lines_without_sending
    configuration = configuration_with(storage: sitemap_storage)
    Rake::Task.define_task(:environment)
    task = Rake::Task["indexmap:index_now:plan"]
    task.reenable
    output, = Indexmap.stub(:configuration, configuration) { capture_io { task.invoke } }
    rows = output.lines.map { |line| JSON.parse(line) }
    assert_equal 2, rows.size
    assert rows.all? { |row| row.fetch("selected") && row.fetch("missing_key") }
    assert_not_requested(:post, "https://api.indexnow.org/indexnow")
  end

  def test_ping_task_report_contains_exact_attempts_and_a_summary
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY
    stub_request(:post, "https://api.indexnow.org/indexnow").to_return(status: 200)
    Rake::Task.define_task(:environment)
    task = Rake::Task["indexmap:index_now:ping"]
    task.reenable
    with_env("INDEXNOW_REPORT" => "1") do
      output, = Indexmap.stub(:configuration, configuration) { capture_io { task.invoke } }
      events = output.lines.map { |line| JSON.parse(line) }
      assert_equal %w[attempt_started attempt_finished summary], events.map { |event| event.fetch("event") }
      assert_equal 2, events.first.fetch("urls").size
      assert_equal "received", events[1].fetch("receipt")
      assert_equal "submitted", events.last.fetch("status")
      refute_includes output, VALID_KEY
    end
  end

  def test_invalid_sitemap_fails_before_any_submission
    configuration = configuration_with(storage: sitemap_storage)
    configuration.index_now.key = VALID_KEY
    configuration.storage.write("sitemap-insights.xml", '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://private.example/secret</loc></url></urlset>')
    assert_raises(Indexmap::ValidationError) { Indexmap::Pinger::IndexNow.new(configuration: configuration).ping }
    assert_not_requested(:post, "https://api.indexnow.org/indexnow")
  end

  private

  def with_env(overrides)
    previous_values = overrides.to_h { |key, _value| [key, ENV[key]] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def configuration_with(storage: Indexmap::Storage::Memory.new(public_url: "https://www.example.com"), index_filename: "sitemap.xml")
    Indexmap::Configuration.new.tap do |configuration|
      configuration.base_url = "https://www.example.com"
      configuration.index_filename = index_filename
      configuration.storage = storage
    end
  end

  def sitemap_storage(marketing_lastmod: "2026-04-18T00:00:00Z", insights_lastmod: "2026-04-10T00:00:00Z")
    Indexmap::Storage::Memory.new(public_url: "https://www.example.com").tap do |storage|
      write_sitemap_files(storage, marketing_lastmod: marketing_lastmod, insights_lastmod: insights_lastmod)
    end
  end

  def write_sitemap_files(storage, marketing_lastmod:, insights_lastmod:)
    storage.write("sitemap.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://www.example.com/sitemap-marketing.xml</loc></sitemap>
        <sitemap><loc>https://www.example.com/sitemap-insights.xml</loc></sitemap>
      </sitemapindex>
    XML

    storage.write("sitemap-marketing.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url>
          <loc>https://www.example.com/pages/features</loc>
          <lastmod>#{marketing_lastmod}</lastmod>
        </url>
      </urlset>
    XML

    storage.write("sitemap-insights.xml", <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url>
          <loc>https://www.example.com/insights/us/restaurants/overview</loc>
          <lastmod>#{insights_lastmod}</lastmod>
        </url>
      </urlset>
    XML
  end
end
