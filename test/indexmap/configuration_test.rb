# frozen_string_literal: true

require "test_helper"

class IndexmapConfigurationTest < Minitest::Test
  def teardown
    Indexmap.reset!
  end

  def test_writer_builds_from_configured_callables
    Indexmap.configure do |config|
      config.base_url = -> { "https://example.com" }
      config.sections = -> do
        [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [Indexmap::Entry.new(loc: "https://example.com/")])]
      end
    end

    files = Indexmap.configuration.writer.write

    assert_includes files.find { |file| file.filename == "sitemap.xml" }.body, "<loc>https://example.com/sitemap-pages.xml</loc>"
    assert_includes files.find { |file| file.filename == "sitemap-pages.xml" }.body, "<loc>https://example.com/</loc>"
  end

  def test_create_writes_to_configured_storage
    storage = Indexmap::Storage::Memory.new

    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.storage = storage
      config.sections = [
        Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [Indexmap::Entry.new(loc: "https://example.com/")])
      ]
    end

    files = Indexmap.create

    assert_equal ["sitemap-pages.xml", "sitemap.xml"], files
    assert_includes storage.read("sitemap.xml"), "<loc>https://example.com/sitemap-pages.xml</loc>"
    assert_includes storage.read("sitemap-pages.xml"), "<loc>https://example.com/</loc>"
  end

  def test_writer_builds_single_file_writer_from_configured_entries
    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.format = :single_file
      config.entries = -> { [Indexmap::Entry.new(loc: "https://example.com/")] }
    end

    files = Indexmap.configuration.writer.write

    assert_equal ["sitemap.xml"], files.map(&:filename)
    assert_includes files.fetch(0).body, "<urlset"
    assert_includes files.fetch(0).body, "<loc>https://example.com/</loc>"
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
      config.index_now.key_filename = -> { "index-now-key.txt" }
      config.index_now.max_urls_per_request = -> { 250 }
      config.index_now.write_key_file = -> { false }
    end

    assert_equal "{\"type\":\"service_account\"}", Indexmap.configuration.google.credentials
    assert_equal "sc-domain:example.com", Indexmap.configuration.google.property
    assert_equal "example-key", Indexmap.configuration.index_now.key
    assert_equal "index-now-key.txt", Indexmap.configuration.index_now.key_filename
    assert_equal 250, Indexmap.configuration.index_now.max_urls_per_request
    refute Indexmap.configuration.index_now.write_key_file?
  end

  def test_index_now_key_file_writing_defaults_to_configured_key_presence
    config = Indexmap::Configuration.new

    refute config.index_now.write_key_file?

    config.index_now.key = "1234567890abcdef1234567890abcdef"

    assert config.index_now.write_key_file?
  end

  def test_index_now_key_file_writing_can_be_disabled_with_a_configured_key
    config = Indexmap::Configuration.new
    config.index_now.key = "1234567890abcdef1234567890abcdef"
    config.index_now.write_key_file = false

    refute config.index_now.write_key_file?
  end

  def test_named_outputs_inherit_configuration_defaults
    storage = Indexmap::Storage::Memory.new

    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.storage = storage
      config.output :reports do |output|
        output.sections = [
          Indexmap::Section.new(
            filename: "sitemap-reports.xml",
            entries: [Indexmap::Entry.new(loc: "https://example.com/reports")]
          )
        ]
      end
    end

    files = Indexmap.create(:reports)

    assert_equal ["sitemap-reports.xml", "sitemap.xml"], files
    assert_includes storage.read("sitemap.xml"), "https://example.com/sitemap-reports.xml"
  end

  def test_create_writes_single_file_named_output_without_default_index
    storage = Indexmap::Storage::Memory.new

    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.storage = storage
      config.output :dynamic do |output|
        output.format = :single_file
        output.index_filename = "sitemap-dynamic.xml"
        output.entries = [
          Indexmap::Entry.new(loc: "https://example.com/dynamic")
        ]
      end
    end

    files = Indexmap.create(:dynamic)

    assert_equal ["sitemap-dynamic.xml"], files
    refute storage.exist?("sitemap.xml")
    assert_includes storage.read("sitemap-dynamic.xml"), "https://example.com/dynamic"
  end

  def test_create_preserves_existing_files_when_validation_fails
    storage = Indexmap::Storage::Memory.new
    storage.write("sitemap.xml", "old index")
    storage.write("sitemap-pages.xml", "old child")

    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.storage = storage
      config.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about?utm_source=test")]
        )
      ]
    end

    error = assert_raises(Indexmap::ValidationError) { Indexmap.create }

    assert_match "Parameterized sitemap URLs detected", error.message
    assert_equal "old index", storage.read("sitemap.xml")
    assert_equal "old child", storage.read("sitemap-pages.xml")
  end

  def test_after_create_requires_a_block
    error = assert_raises(ArgumentError) { Indexmap.configuration.after_create }

    assert_equal "after_create requires a block", error.message
  end
end
