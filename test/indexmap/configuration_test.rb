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

  def test_named_outputs_inherit_configuration_defaults
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.public_path = public_path
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

      assert_equal [
        public_path.join("sitemap-reports.xml"),
        public_path.join("sitemap.xml")
      ], files
      assert_includes public_path.join("sitemap.xml").read, "https://example.com/sitemap-reports.xml"
    end
  end

  def test_create_writes_named_output_to_public_path
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.public_path = public_path
        config.output :dynamic do |output|
          output.sections = [
            Indexmap::Section.new(
              filename: "sitemap-dynamic.xml",
              entries: [Indexmap::Entry.new(loc: "https://example.com/dynamic")]
            )
          ]
        end
      end

      files = Indexmap.create(:dynamic)

      assert_equal [
        public_path.join("sitemap-dynamic.xml"),
        public_path.join("sitemap.xml")
      ], files
      assert_includes public_path.join("sitemap-dynamic.xml").read, "https://example.com/dynamic"
      assert_includes public_path.join("sitemap.xml").read, "https://example.com/sitemap-dynamic.xml"
    end
  end

  def test_create_preserves_existing_files_when_validation_fails
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap.xml").write("old index")
      public_path.join("sitemap-pages.xml").write("old child")

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.public_path = public_path
        config.sections = [
          Indexmap::Section.new(
            filename: "sitemap-pages.xml",
            entries: [Indexmap::Entry.new(loc: "https://example.com/about?utm_source=test")]
          )
        ]
      end

      error = assert_raises(Indexmap::ValidationError) { Indexmap.create }

      assert_match "Parameterized sitemap URLs detected", error.message
      assert_equal "old index", public_path.join("sitemap.xml").read
      assert_equal "old child", public_path.join("sitemap-pages.xml").read
    end
  end

  def test_create_writes_single_file_named_output_without_default_index
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.public_path = public_path
        config.output :dynamic do |output|
          output.format = :single_file
          output.index_filename = "sitemap-dynamic.xml"
          output.entries = [
            Indexmap::Entry.new(loc: "https://example.com/dynamic")
          ]
        end
      end

      files = Indexmap.create(:dynamic)

      assert_equal [public_path.join("sitemap-dynamic.xml")], files
      refute public_path.join("sitemap.xml").exist?
      assert_includes public_path.join("sitemap-dynamic.xml").read, "https://example.com/dynamic"
    end
  end

  def test_create_preserves_existing_named_output_when_validation_fails
    Dir.mktmpdir do |dir|
      public_path = Pathname(dir)
      public_path.join("sitemap-dynamic.xml").write("old dynamic")

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.public_path = public_path
        config.output :dynamic do |output|
          output.format = :single_file
          output.index_filename = "sitemap-dynamic.xml"
          output.entries = [
            Indexmap::Entry.new(loc: "https://example.com/dynamic?utm_source=test")
          ]
        end
      end

      error = assert_raises(Indexmap::ValidationError) { Indexmap.create(:dynamic) }

      assert_match "Parameterized sitemap URLs detected", error.message
      assert_equal "old dynamic", public_path.join("sitemap-dynamic.xml").read
    end
  end

  def test_after_create_requires_a_block
    error = assert_raises(ArgumentError) { Indexmap.configuration.after_create }

    assert_equal "after_create requires a block", error.message
  end
end
