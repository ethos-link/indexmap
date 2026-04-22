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

      Indexmap::TaskRunner.new(configuration: configuration).create

      assert_equal false, public_path.join("sitemap-pages.xml.gz").exist?
      assert_includes public_path.join("sitemap.xml").read, "<sitemapindex"
      assert_equal "test-key\n", public_path.join("test-key.txt").read
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
end
