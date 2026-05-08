# frozen_string_literal: true

require "test_helper"

class IndexmapTaskRunnerTest < Minitest::Test
  VALID_KEY = "1234567890abcdef1234567890abcdef"

  class KeywordContentTypeStorage < Indexmap::Storage::Memory
    def write(filename, body, content_type:)
      super
    end

    def read_file(filename)
      instance_variable_get(:@files).fetch(filename)
    end
  end

  def test_create_writes_new_sitemap_and_key_file_without_deleting_unrelated_files
    storage = Indexmap::Storage::Memory.new
    storage.write("sitemap-pages.xml.gz", "old")
    storage.write("sitemap-extra.xml", "existing")

    configuration = configuration_with(storage: storage)
    configuration.index_now.key = VALID_KEY

    result = Indexmap::TaskRunner.new(configuration: configuration).create

    assert storage.exist?("sitemap-pages.xml.gz")
    assert_equal "existing", storage.read("sitemap-extra.xml")
    assert_includes storage.read("sitemap.xml"), "<sitemapindex"
    assert_equal VALID_KEY, storage.read("#{VALID_KEY}.txt")
    assert_equal ["sitemap-pages.xml", "sitemap.xml"], result[:files]
    assert_equal ["sitemap-pages.xml", "sitemap.xml"], result[:written_files]
    assert_equal "#{VALID_KEY}.txt", result[:index_now_key_filename]
  end

  def test_create_runs_after_create_callbacks_after_validation
    calls = []
    storage = Indexmap::Storage::Memory.new
    configuration = configuration_with(storage: storage)
    configuration.after_create do
      calls << :called
      calls << storage.read("sitemap.xml").include?("<sitemapindex")
    end

    Indexmap::TaskRunner.new(configuration: configuration).create

    assert_equal [:called, true], calls
  end

  def test_create_reuses_existing_index_now_key_file
    storage = Indexmap::Storage::Memory.new
    storage.write("#{VALID_KEY}.txt", VALID_KEY, content_type: "text/plain")
    configuration = configuration_with(storage: storage)
    configuration.index_now.key = VALID_KEY

    result = Indexmap::TaskRunner.new(configuration: configuration).create

    assert_equal "#{VALID_KEY}.txt", result[:index_now_key_filename]
    assert_equal VALID_KEY, storage.read("#{VALID_KEY}.txt")
  end

  def test_create_can_skip_index_now_key_file_writing
    storage = Indexmap::Storage::Memory.new
    configuration = configuration_with(storage: storage)
    configuration.index_now.key = VALID_KEY
    configuration.index_now.write_key_file = false

    result = Indexmap::TaskRunner.new(configuration: configuration).create

    refute storage.exist?("#{VALID_KEY}.txt")
    assert_nil result[:index_now_key_filename]
    assert_equal ["sitemap-pages.xml", "sitemap.xml"], result[:files]
  end

  def test_write_index_now_key_returns_nil_when_key_is_not_configured
    result = Indexmap::TaskRunner.new(configuration: configuration_with).write_index_now_key

    assert_nil result
  end

  def test_write_index_now_key_can_generate_a_key_when_requested
    storage = Indexmap::Storage::Memory.new
    configuration = configuration_with(storage: storage)

    result = Indexmap::TaskRunner.new(configuration: configuration).write_index_now_key(generate_if_missing: true)

    assert_match(/\A[a-f0-9]{32}\.txt\z/, result)
    assert_equal result.delete_suffix(".txt"), storage.read(result)
  end

  def test_format_passes_content_type_when_rewriting_sitemaps
    storage = KeywordContentTypeStorage.new
    storage.write("sitemap.xml", <<~XML, content_type: "application/xml")
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://example.com/about</loc></url></urlset>
    XML
    configuration = configuration_with(storage: storage)

    result = Indexmap::TaskRunner.new(configuration: configuration).format

    assert_equal ["sitemap.xml"], result
    assert_equal "application/xml", storage.read_file("sitemap.xml").content_type
    assert_includes storage.read("sitemap.xml"), "\n  <url>"
  end

  private

  def configuration_with(storage: Indexmap::Storage::Memory.new)
    Indexmap::Configuration.new.tap do |configuration|
      configuration.base_url = "https://example.com"
      configuration.storage = storage
      configuration.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ]
    end
  end
end
