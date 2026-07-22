# frozen_string_literal: true

require "test_helper"

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
