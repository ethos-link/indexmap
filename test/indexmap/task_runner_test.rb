# frozen_string_literal: true

require "test_helper"

class IndexmapTaskRunnerTest < Minitest::Test
  def test_create_removes_existing_sitemap_files_writes_new_sitemap_and_key_file
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap.xml").write("old")
      public_path.join("sitemap-pages.xml.gz").write("old")

      configuration = Indexmap::Configuration.new
      configuration.base_url = "https://example.com"
      configuration.public_path = public_path
      configuration.sections = [
        Indexmap::Section.new(
          filename: "sitemap-pages.xml",
          entries: [Indexmap::Entry.new(loc: "https://example.com/about")]
        )
      ]
      configuration.index_now.key = "test-key"

      result = Indexmap::TaskRunner.new(configuration: configuration).create

      assert_equal false, public_path.join("sitemap-pages.xml.gz").exist?
      assert_includes public_path.join("sitemap.xml").read, "<sitemapindex"
      assert_equal "test-key\n", public_path.join("test-key.txt").read
      assert_equal [public_path.join("sitemap-pages.xml").to_s, public_path.join("sitemap.xml").to_s], result[:files]
      assert_equal public_path.join("test-key.txt"), result[:index_now_key_path]
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

      assert_match(/\A[a-z0-9-]{8,128}\.txt\z/, result.basename.to_s)
      assert_equal "#{result.basename(".txt")}\n", result.read
    end
  end
end
