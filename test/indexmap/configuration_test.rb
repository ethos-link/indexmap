# frozen_string_literal: true

require "test_helper"

class IndexmapConfigurationTest < Minitest::Test
  def teardown
    Indexmap.reset!
  end

  def test_writer_builds_from_configured_callables
    Indexmap.configure do |config|
      config.base_url = -> { "https://example.com" }
      config.public_path = -> { Pathname("tmp/public") }
      config.sections = -> do
        [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: [Indexmap::Entry.new(loc: "https://example.com/")])]
      end
    end

    writer = Indexmap.configuration.writer

    assert_equal Pathname("tmp/public"), writer.instance_variable_get(:@public_path)
  end

  def test_writer_builds_single_file_writer_from_configured_entries
    Indexmap.configure do |config|
      config.base_url = "https://example.com"
      config.format = :single_file
      config.entries = -> { [Indexmap::Entry.new(loc: "https://example.com/")] }
    end

    writer = Indexmap.configuration.writer

    assert_equal :single_file, writer.instance_variable_get(:@format)
    assert_equal [Indexmap::Entry.new(loc: "https://example.com/")], writer.instance_variable_get(:@entries)
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
end
