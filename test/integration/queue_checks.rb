# frozen_string_literal: true

require "minitest/autorun"
require "indexmap"
require "timeout"
require "rbconfig"

class QueueChecks < Minitest::Test
  def setup
    Indexmap.reset!
    load Rails.root.join("config/initializers/indexmap.rb")
    PublicPage.delete_all
    5.times { |id| PublicPage.create!(slug: "page-#{id}", published: true) }
  end

  def test_http_serves_the_configured_publication_without_evaluating_sources
    result = Indexmap::TaskRunner.new.create
    Indexmap.configuration.sections = -> { raise "HTTP must not evaluate source records" }
    client = Rack::MockRequest.new(Rails.application)

    root = client.get("/sitemap.xml")
    assert_equal 200, root.status
    assert_includes root.body, result.fetch(:files).first
    child = client.get("/" + result.fetch(:files).first)
    assert_equal 200, child.status
    assert_includes child.body, "https://example.com/page-0"
    assert_includes child["cache-control"], "immutable"
  end

  def test_good_job_executes_database_projection_and_surfaces_validation_failure
    IntegrationRefreshJob.queue_adapter = :good_job
    job = IntegrationRefreshJob.perform_later
    GoodJob.perform_inline
    assert GoodJob::Job.find(job.provider_job_id).finished_at
    assert_equal 5, Indexmap::Parser.new.entries.size
    previous = Indexmap.configuration.storage.read("sitemap.xml")
    PublicPage.create!(slug: "page-0", published: true)
    IntegrationRefreshJob.perform_later
    assert_raises(Indexmap::ValidationError) { GoodJob.perform_inline }
    assert_equal previous, Indexmap.configuration.storage.read("sitemap.xml")
  end

  def test_solid_queue_worker_executes_and_records_failed_generation
    IntegrationRefreshJob.queue_adapter = :solid_queue
    reader, writer = IO.pipe
    pid = Process.spawn({"INDEXMAP_ADAPTER" => "solid_queue"}, RbConfig.ruby, "bin/jobs",
      chdir: Rails.root, out: writer, err: writer, pgroup: true)
    writer.close
    job = IntegrationRefreshJob.perform_later
    wait_for(reader) { SolidQueue::Job.find_by(active_job_id: job.job_id)&.finished_at }
    assert_equal 5, Indexmap::Parser.new.entries.size
    previous = Indexmap.configuration.storage.read("sitemap.xml")
    PublicPage.create!(slug: "page-0", published: true)
    failed = IntegrationRefreshJob.perform_later
    wait_for(reader) { SolidQueue::FailedExecution.joins(:job).where(solid_queue_jobs: {active_job_id: failed.job_id}).exists? }
    assert_equal previous, Indexmap.configuration.storage.read("sitemap.xml")
  ensure
    if pid
      Process.kill("TERM", -pid)
      Timeout.timeout(15) { Process.wait(pid) }
    end
    reader&.close
    writer&.close unless writer&.closed?
  end

  def test_active_storage_atomic_publication_and_retention
    config = Indexmap.configuration
    config.storage = Indexmap::Storage::ActiveStorage.new(model: SitemapArtifact, public_url: config.base_url)
    first = Indexmap.create
    previous = config.storage.read("sitemap.xml")
    SitemapArtifact.find_by!(filename: "sitemap.xml").file.blob.update!(created_at: 4.days.ago)
    revision = config.storage.revision("sitemap.xml")
    config.storage.define_singleton_method(:open) do |filename, &block|
      raise "Root body must not be downloaded during activation" if filename == "sitemap.xml"

      super(filename, &block)
    end
    second = Indexmap.create
    config.storage.singleton_class.remove_method(:open)
    refute_equal first, second
    assert_empty config.storage.prune(root: "sitemap.xml", before: 2.days.ago)
    assert first.all? { |filename| config.storage.exist?(filename) }
    assert_raises(Indexmap::SupersededPublication) do
      Dir.mktmpdir do |directory|
        staged = Indexmap::Storage::Filesystem.new(path: directory)
        staged.write("sitemap.xml", previous)
        config.storage.publish(staged, files: ["sitemap.xml"], root: "sitemap.xml", expected: revision)
      end
    end
    assert Indexmap::Validator.new(configuration: config).validate!
    config.storage.prune(root: "sitemap.xml", before: Time.now.utc + 1)
    assert (first - ["sitemap.xml"]).none? { |filename| config.storage.exist?(filename) }
    assert second.all? { |filename| config.storage.exist?(filename) }
  end

  def test_active_storage_rejects_stale_builds_without_uploading
    config = active_storage_configuration("stale.xml")
    Indexmap.create(configuration: config)
    expected = config.storage.revision(config.index_filename)
    Indexmap.create(configuration: config)
    blobs = ActiveStorage::Blob.order(:id).pluck(:id)
    assert_raises(Indexmap::SupersededPublication) do
      config.storage.publish(nil, files: [], root: config.index_filename, expected: expected)
    end
    assert_equal blobs, ActiveStorage::Blob.order(:id).pluck(:id)
  end

  def test_active_storage_cleans_partial_uploads_synchronously
    config = active_storage_configuration("failed-upload.xml")
    Indexmap.create(configuration: config)
    previous = config.storage.read(config.index_filename)
    blobs = ActiveStorage::Blob.order(:id).pluck(:id)
    records = SitemapArtifact.order(:id).pluck(:id)
    service = ActiveStorage::Blob.service
    uploaded = []
    service.define_singleton_method(:upload) do |key, io, **options|
      super(key, io, **options)
      uploaded << key
      raise IOError, "upload interrupted after object write" if uploaded.size == 2
    end
    assert_raises(IOError) { Indexmap.create(configuration: config) }
    assert_equal previous, config.storage.read(config.index_filename)
    assert_equal blobs, ActiveStorage::Blob.order(:id).pluck(:id)
    assert_equal records, SitemapArtifact.order(:id).pluck(:id)
    assert uploaded.none? { |key| service.exist?(key) }
    assert Indexmap::Validator.new(configuration: config).validate!
  ensure
    service&.singleton_class&.remove_method(:upload)
  end

  def test_active_storage_cleans_a_losing_build_without_pruning
    config = active_storage_configuration("race.xml")
    storage = config.storage
    baseline = ActiveStorage::Blob.pluck(:id)
    lost_files = []
    lost_keys = []
    winner = nil
    storage.define_singleton_method(:publish) do |source, **options|
      lost_files.concat(options.fetch(:files).reject { |name| name == options.fetch(:root) })
      source.define_singleton_method(:open) do |filename, &block|
        if filename == options.fetch(:root)
          lost_keys.concat(ActiveStorage::Blob.where.not(id: baseline).pluck(:key))
          competing = Indexmap::Configuration.new
          competing.base_url = config.base_url
          competing.index_filename = config.index_filename
          competing.atomic = true
          competing.sections = config.sections
          competing.storage = Indexmap::Storage::ActiveStorage.new(model: SitemapArtifact, public_url: config.base_url)
          winner = Indexmap.create(configuration: competing)
        end
        super(filename, &block)
      end
      super(source, **options)
    end
    assert_raises(Indexmap::SupersededPublication) { Indexmap.create(configuration: config) }
    assert_equal winner.size, ActiveStorage::Blob.where.not(id: baseline).count
    assert lost_files.none? { |filename| storage.exist?(filename) }
    assert lost_keys.none? { |key| ActiveStorage::Blob.service.exist?(key) }
    assert winner.all? { |filename| storage.exist?(filename) }
    assert Indexmap::Validator.new(configuration: config).validate!
  end

  def test_active_storage_does_not_activate_children_deleted_by_pruning
    config = active_storage_configuration("prune-race.xml")
    Indexmap.create(configuration: config)
    previous = config.storage.read(config.index_filename)
    blobs = ActiveStorage::Blob.pluck(:id).sort
    config.storage.define_singleton_method(:publish) do |source, **options|
      storage = self
      source.define_singleton_method(:open) do |filename, &block|
        storage.prune(root: options.fetch(:root), before: Time.now.utc + 1) if filename == options.fetch(:root)
        super(filename, &block)
      end
      super(source, **options)
    end
    assert_raises(Indexmap::SupersededPublication) { Indexmap.create(configuration: config) }
    assert_equal previous, config.storage.read(config.index_filename)
    assert_equal blobs, ActiveStorage::Blob.pluck(:id).sort
    assert Indexmap::Validator.new(configuration: config).validate!
  end

  def test_active_storage_preserves_a_commit_when_a_host_callback_raises
    config = active_storage_configuration("callback.xml")
    callback = proc do |record|
      if record.filename == "callback.xml" && record.file.attached?
        raise IOError, "host callback failed after commit"
      end
    end
    SitemapArtifact.set_callback(:commit, :after, callback)
    assert_raises(IOError) { Indexmap.create(configuration: config) }
    assert config.storage.exist?(config.index_filename)
    assert Indexmap::Validator.new(configuration: config).validate!
  ensure
    SitemapArtifact.skip_callback(:commit, :after, callback) if callback
  end

  def test_active_storage_reports_cleanup_failures_and_attempts_remaining_objects
    config = active_storage_configuration("cleanup-error.xml")
    Indexmap.create(configuration: config)
    previous = config.storage.read(config.index_filename)
    service = ActiveStorage::Blob.service
    uploaded = []
    attempted = []
    service.define_singleton_method(:upload) do |key, io, **options|
      super(key, io, **options)
      uploaded << key
      raise IOError, "original upload failure" if uploaded.size == 2
    end
    service.define_singleton_method(:delete) do |key|
      attempted << key
      raise IOError, "cleanup unavailable" if key == uploaded.first

      super(key)
    end
    error = assert_raises(Indexmap::PublicationCleanupError) { Indexmap.create(configuration: config) }
    assert_equal "original upload failure", error.cause.message
    assert_equal [uploaded.first], error.failures.map { |failure| failure.fetch(:artifact) }
    assert_equal uploaded.sort, attempted.sort
    assert_equal previous, config.storage.read(config.index_filename)
    assert Indexmap::Validator.new(configuration: config).validate!
  ensure
    if service
      service.singleton_class.remove_method(:upload)
      service.singleton_class.remove_method(:delete)
      uploaded&.each { |key| service.delete(key) }
    end
  end

  def test_active_storage_publishes_atomic_single_file_outputs
    config = active_storage_configuration("single.xml")
    config.format = :single_file
    config.entries = [{loc: "https://example.com/page"}]
    assert_equal ["single.xml"], Indexmap.create(configuration: config)
    assert_equal ["single.xml"], Indexmap.create(configuration: config)
    assert Indexmap::Validator.new(configuration: config).validate!
  end

  private

  def active_storage_configuration(root)
    Indexmap.configuration.tap do |config|
      config.index_filename = root
      config.storage = Indexmap::Storage::ActiveStorage.new(model: SitemapArtifact, public_url: config.base_url)
    end
  end

  def wait_for(reader)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    log = +""
    until yield
      raise "Worker did not reach expected state: #{log[-2000, 2000]}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      if IO.select([reader], nil, nil, 0.1)
        chunk = reader.read_nonblock(4096, exception: false)
        log << chunk if chunk.is_a?(String)
      end
    end
  end
end
