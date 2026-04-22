# frozen_string_literal: true

require "test_helper"

class IndexmapPingerIndexNowTest < Minitest::Test
  def test_writes_key_file_from_configuration
    Dir.mktmpdir do |dir|
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = Pathname(dir)
      configuration.index_now.key = "test-key"

      path = Indexmap::Pinger::IndexNow.new(configuration: configuration).write_key_file

      assert_equal Pathname(dir).join("test-key.txt"), path
      assert_equal "test-key\n", path.read
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
      configuration.index_now.key = "test-key"

      indexnow_url = "https://api.indexnow.org/indexnow"
      stub_request(:post, indexnow_url).to_return(status: 200, body: "", headers: {})

      Indexmap::Pinger::IndexNow.new(configuration: configuration).ping

      assert_requested(:post, indexnow_url, times: 1) do |request|
        payload = JSON.parse(request.body)
        assert_equal [
          "https://www.example.com/pages/features",
          "https://www.example.com/insights/us/restaurants/overview"
        ].sort, payload.fetch("urlList").sort
      end
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
      configuration.index_now.key = "test-key"

      indexnow_url = "https://api.indexnow.org/indexnow"
      stub_request(:post, indexnow_url).to_return(status: 200, body: "", headers: {})

      with_env("SINCE" => "2026-04-15T00:00:00Z") do
        Indexmap::Pinger::IndexNow.new(configuration: configuration).ping
      end

      assert_requested(:post, indexnow_url, times: 1) do |request|
        payload = JSON.parse(request.body)
        assert_equal ["https://www.example.com/pages/features"], payload.fetch("urlList")
      end
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
