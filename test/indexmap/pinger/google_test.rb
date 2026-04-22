# frozen_string_literal: true

require "test_helper"

class IndexmapPingerGoogleTest < Minitest::Test
  SiteEntry = Struct.new(:site_url)
  SiteList = Struct.new(:site_entry)

  class FakeWebmastersService
    attr_accessor :authorization
    attr_reader :submitted

    def initialize(site_urls:)
      @site_urls = site_urls
    end

    def list_sites
      SiteList.new(@site_urls.map { |site_url| SiteEntry.new(site_url) })
    end

    def submit_sitemap(property, sitemap_url)
      @submitted = [property, sitemap_url]
    end
  end

  def test_pings_google_for_each_sitemap_file
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap.xml").write("<sitemapindex/>")

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path
      configuration.google.credentials = "{\"type\":\"service_account\"}"

      service = FakeWebmastersService.new(site_urls: ["sc-domain:example.com"])
      builder_calls = []
      credentials_builder = lambda do |credentials:, scope:|
        builder_calls << [credentials, scope]
        :fake_authorizer
      end

      Indexmap::Pinger::Google.new(
        configuration: configuration,
        service: service,
        credentials_builder: credentials_builder
      ).ping

      assert_equal [["{\"type\":\"service_account\"}", "https://www.googleapis.com/auth/webmasters"]], builder_calls
      assert_equal :fake_authorizer, service.authorization
      assert_equal ["sc-domain:example.com", "https://www.example.com/sitemap.xml"], service.submitted
    end
  end

  def test_skips_google_ping_when_credentials_are_missing
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap.xml").write("<sitemapindex/>")

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://www.example.com"
      configuration.public_path = public_path

      service = FakeWebmastersService.new(site_urls: ["sc-domain:example.com"])

      Indexmap::Pinger::Google.new(configuration: configuration, service: service).ping

      assert_nil service.submitted
    end
  end
end
