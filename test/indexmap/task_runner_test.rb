# frozen_string_literal: true

require "test_helper"

class IndexmapTaskRunnerTest < Minitest::Test
  VALID_KEY = "1234567890abcdef1234567890abcdef"

  def test_create_writes_new_sitemap_and_key_file_without_deleting_unrelated_files
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap.xml").write("old")
      public_path.join("sitemap-pages.xml.gz").write("old")
      public_path.join("sitemap-extra.xml").write("existing")

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"
      configuration.public_path = public_path
      configuration.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ]
      configuration.index_now.key = VALID_KEY

      result = Indexmap::TaskRunner.new(configuration: configuration).create

      assert public_path.join("sitemap-pages.xml.gz").exist?
      assert_equal "existing", public_path.join("sitemap-extra.xml").read
      assert_includes public_path.join("sitemap.xml").read, "<sitemapindex"
      assert_equal VALID_KEY, public_path.join("#{VALID_KEY}.txt").read
      assert_equal [public_path.join("sitemap-pages.xml").to_s, public_path.join("sitemap.xml").to_s], result[:files]
      assert_equal [public_path.join("sitemap-pages.xml"), public_path.join("sitemap.xml")], result[:written_files]
      assert_equal public_path.join("#{VALID_KEY}.txt"), result[:index_now_key_path]
    end
  end

  def test_create_runs_after_create_callbacks_after_validation
    Dir.mktmpdir do |dir|
      calls = []
      public_path = Pathname(dir)
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"
      configuration.public_path = public_path
      configuration.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ]
      configuration.after_create do
        calls << :called
        calls << public_path.join("sitemap.xml").read.include?("<sitemapindex")
      end

      Indexmap::TaskRunner.new(configuration: configuration).create

      assert_equal [:called, true], calls
    end
  end

  def test_create_reuses_existing_index_now_key_file
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      key_path = public_path.join("#{VALID_KEY}.txt")
      key_path.write(VALID_KEY)
      previous_mtime = key_path.mtime
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"
      configuration.public_path = public_path
      configuration.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ]
      configuration.index_now.key = VALID_KEY

      sleep 0.01
      result = Indexmap::TaskRunner.new(configuration: configuration).create

      assert_equal key_path, result[:index_now_key_path]
      assert_equal previous_mtime, key_path.mtime
      assert_equal VALID_KEY, key_path.read
    end
  end

  def test_create_can_skip_index_now_key_file_writing
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"
      configuration.public_path = public_path
      configuration.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ]
      configuration.index_now.key = VALID_KEY
      configuration.index_now.write_key_file = false

      result = Indexmap::TaskRunner.new(configuration: configuration).create

      refute public_path.join("#{VALID_KEY}.txt").exist?
      assert_nil result[:index_now_key_path]
      assert_equal [public_path.join("sitemap-pages.xml").to_s, public_path.join("sitemap.xml").to_s], result[:files]
    end
  end

  def test_write_index_now_key_returns_nil_when_key_is_not_configured
    Dir.mktmpdir do |dir|
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"
      configuration.public_path = Pathname(dir)
      configuration.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ]

      result = Indexmap::TaskRunner.new(configuration: configuration).write_index_now_key

      assert_nil result
    end
  end

  def test_write_index_now_key_can_generate_a_key_when_requested
    Dir.mktmpdir do |dir|
      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"
      configuration.public_path = Pathname(dir)

      result = Indexmap::TaskRunner.new(configuration: configuration).write_index_now_key(generate_if_missing: true)

      assert_match(/\A[a-f0-9]{32}\.txt\z/, result.basename.to_s)
      assert_equal result.basename(".txt").to_s, result.read
    end
  end
end
