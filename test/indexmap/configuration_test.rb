# frozen_string_literal: true

require "test_helper"

class IndexmapConfigurationTest < Minitest::Test
  def teardown
    Indexmap.reset!
  end

  def test_writer_builds_from_configured_callables
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)

      Indexmap.configure do |config|
        config.base_url = -> { "https://example.com" }
        config.public_path = -> { public_path }
        config.sections = -> do
          [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [Indexmap::Entry.new(loc: "https://example.com/")])]
        end
      end

      Indexmap.configuration.writer.write

      assert_includes public_path.join("sitemap.xml").read, "<loc>https://example.com/sitemap-pages.xml</loc>"
      assert_includes public_path.join("sitemap-pages.xml").read, "<loc>https://example.com/</loc>"
    end
  end

  def test_writer_builds_single_file_writer_from_configured_entries
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.public_path = public_path
        config.format = :single_file
        config.entries = -> { [Indexmap::Entry.new(loc: "https://example.com/")] }
      end

      Indexmap.configuration.writer.write

      assert_includes public_path.join("sitemap.xml").read, "<urlset"
      assert_includes public_path.join("sitemap.xml").read, "<loc>https://example.com/</loc>"
      refute public_path.join("sitemap-pages.xml").exist?
    end
  end

  def test_writer_raises_without_base_url
    Indexmap.configure do |config|
      config.sections = [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [])]
    end

    error = assert_raises(Indexmap::ConfigurationError) { Indexmap.configuration.writer }

    assert_equal "Indexmap base_url is not configured", error.message
  end

  def test_writer_raises_without_entries_in_single_file_mode
    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.format = :single_file
    end

    error = assert_raises(Indexmap::ConfigurationError) { Indexmap.configuration.writer }

    assert_equal "Indexmap entries are not configured", error.message
  end

  def test_writer_raises_for_invalid_format
    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.format = :unsupported
      config.sections = [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [])]
    end

    error = assert_raises(Indexmap::ConfigurationError) { Indexmap.configuration.writer }

    assert_equal "Indexmap format must be one of: index, single_file", error.message
  end

  def test_exposes_nested_google_and_index_now_configuration
    Indexmap.configure do |config|
      config.google.credentials = -> { "{\"type\":\"service_account\"}" }
      config.google.property = -> { "sc-domain:example.com" }
      config.index_now.key = -> { "example-key" }
      config.index_now.max_urls_per_request = -> { 250 }
    end

    assert_equal "{\"type\":\"service_account\"}", Indexmap.configuration.google.credentials
    assert_equal "sc-domain:example.com", Indexmap.configuration.google.property
    assert_equal "example-key", Indexmap.configuration.index_now.key
    assert_equal 250, Indexmap.configuration.index_now.max_urls_per_request
  end
end
