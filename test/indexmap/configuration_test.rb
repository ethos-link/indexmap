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

      artifacts = Indexmap.render(:reports)

      assert_equal %w[sitemap-reports.xml sitemap.xml], artifacts.map(&:filename)
      assert_includes artifacts.find { |artifact| artifact.filename == "sitemap.xml" }.body,
        "https://example.com/sitemap-reports.xml"
    end
  end

  def test_create_uploads_named_output_to_configured_store
    Dir.mktmpdir do |dir|
      store = Indexmap::Stores::File.new(Pathname(dir).join("sitemaps"))

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.store = store
        config.output :dynamic do |output|
          output.sections = [
            Indexmap::Section.new(
              filename: "sitemap-dynamic.xml",
              entries: [Indexmap::Entry.new(loc: "https://example.com/dynamic")]
            )
          ]
        end
      end

      Indexmap.create(:dynamic)

      assert_includes store.fetch!("sitemap-dynamic.xml").body, "https://example.com/dynamic"
      assert_includes store.fetch!("sitemap.xml").body, "https://example.com/sitemap-dynamic.xml"
    end
  end

  def test_create_uploads_single_file_named_output_without_default_index
    Dir.mktmpdir do |dir|
      store = Indexmap::Stores::File.new(Pathname(dir).join("sitemaps"))

      Indexmap.configure do |config|
        config.base_url = "https://example.com"
        config.store = store
        config.output :dynamic do |output|
          output.format = :single_file
          output.index_filename = "sitemap-dynamic.xml"
          output.entries = [
            Indexmap::Entry.new(loc: "https://example.com/dynamic")
          ]
        end
      end

      Indexmap.create(:dynamic)

      assert_nil store.fetch("sitemap.xml")
      assert_includes store.fetch!("sitemap-dynamic.xml").body, "https://example.com/dynamic"
    end
  end

  def test_after_create_callbacks_run_for_task_runner_create
    calls = []

    Indexmap.configure do |config|
      config.after_create { calls << :called }
    end

    Indexmap.configuration.run_after_create_callbacks

    assert_equal [:called], calls
  end
end
