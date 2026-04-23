# frozen_string_literal: true

require "test_helper"

class IndexmapPingerIndexNowTest < Minitest::Test
  VALID_KEY = "1234567890abcdef1234567890abcdef"

  def test_writes_key_file_from_configuration
    Dir.mktmpdir do |dir|
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = Pathname(dir)
      configuration.index_now.key = VALID_KEY

      path = Indexmap::Pinger::IndexNow.new(configuration: configuration).write_key_file

      assert_equal Pathname(dir).join("#{VALID_KEY}.txt"), path
      assert_equal VALID_KEY, path.read
    end
  end

  def test_ensure_key_file_generates_a_key_when_configuration_is_missing
    Dir.mktmpdir do |dir|
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = Pathname(dir)

      path = Indexmap::Pinger::IndexNow.new(configuration: configuration).ensure_key_file

      assert_match(/\A[a-f0-9]{32}\.txt\z/, path.basename.to_s)
      assert_equal path.basename(".txt").to_s, path.read
    end
  end

  def test_pings_using_existing_key_file_when_key_is_not_configured
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      key_path = public_path.join("#{VALID_KEY}.txt")
      key_path.write(VALID_KEY)
      write_sitemap_files(
        public_path,
        marketing_lastmod: "2026-04-18T00:00:00Z",
        insights_lastmod: "2026-04-10T00:00:00Z"
      )

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path

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
  end

  def test_ignores_existing_key_file_with_trailing_newline
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      invalid_key_path = public_path.join("1234567890abcdef1234567890abcdef.txt")
      invalid_key_path.write("#{VALID_KEY}\n")

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path

      path = Indexmap::Pinger::IndexNow.new(configuration: configuration).ensure_key_file

      refute_equal invalid_key_path, path
      assert_match(/\A[a-f0-9]{32}\.txt\z/, path.basename.to_s)
      assert_equal path.basename(".txt").to_s, path.read
    end
  end

  def test_pings_all_sitemap_urls_when_no_cutoff_is_provided
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      write_sitemap_files(
        public_path,
        marketing_lastmod: "2026-04-18T00:00:00Z",
        insights_lastmod: "2026-04-10T00:00:00Z"
      )

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path
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
  end

  def test_pings_only_sitemap_urls_newer_than_since
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      write_sitemap_files(
        public_path,
        marketing_lastmod: "2026-04-18T00:00:00Z",
        insights_lastmod: "2026-04-10T00:00:00Z"
      )

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path
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
  end

  def test_skips_indexnow_ping_when_key_is_missing
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      write_sitemap_files(
        public_path,
        marketing_lastmod: "2026-04-18T00:00:00Z",
        insights_lastmod: "2026-04-10T00:00:00Z"
      )

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path

      result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

      assert_equal({status: :skipped, reason: :missing_key}, result)
    end
  end

  def test_reports_indexnow_dry_run
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      write_sitemap_files(
        public_path,
        marketing_lastmod: "2026-04-18T00:00:00Z",
        insights_lastmod: "2026-04-10T00:00:00Z"
      )

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path
      configuration.index_now.key = VALID_KEY

      with_env("INDEXNOW_DRY_RUN" => "1") do
        result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

        assert_equal :dry_run, result[:status]
        assert_equal 2, result[:url_count]
        assert_equal 1, result[:batch_count]
      end
    end
  end

  def test_reports_failed_indexnow_submission
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      write_sitemap_files(
        public_path,
        marketing_lastmod: "2026-04-18T00:00:00Z",
        insights_lastmod: "2026-04-10T00:00:00Z"
      )

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path
      configuration.index_now.key = VALID_KEY

      indexnow_url = "https://api.indexnow.org/indexnow"
      stub_request(:post, indexnow_url).to_return(status: 500, body: "boom", headers: {})

      result = Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

      assert_equal :failed, result[:status]
      assert_equal 1, result[:failures].count
      assert_equal 500, result[:failures].first[:status_code]
    end
  end

  def test_rejects_invalid_configured_key
    Dir.mktmpdir do |dir|
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = Pathname(dir)
      configuration.index_now.key = "test-key"

      error = assert_raises(Indexmap::ConfigurationError) do
        Indexmap::Pinger::IndexNow.new(configuration: configuration).ping
      end

      assert_equal "IndexNow key must be a 32-character lowercase hexadecimal string", error.message
    end
  end

  def test_reuses_existing_key_file_deterministically
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("ffffffffffffffffffffffffffffffff.txt").write("ffffffffffffffffffffffffffffffff")
      public_path.join("00000000000000000000000000000000.txt").write("00000000000000000000000000000000")

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path

      path = Indexmap::Pinger::IndexNow.new(configuration: configuration).ensure_key_file

      assert_equal public_path.join("00000000000000000000000000000000.txt"), path
    end
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

  def write_sitemap_files(public_path, marketing_lastmod:, insights_lastmod:)
    public_path.join("sitemap.xml").write(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://www.example.com/sitemap-marketing.xml</loc></sitemap>
        <sitemap><loc>https://www.example.com/sitemap-insights.xml</loc></sitemap>
      </sitemapindex>
    XML

    public_path.join("sitemap-marketing.xml").write(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url>
          <loc>https://www.example.com/pages/features</loc>
          <lastmod>#{marketing_lastmod}</lastmod>
        </url>
      </urlset>
    XML

    public_path.join("sitemap-insights.xml").write(<<~XML)
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
