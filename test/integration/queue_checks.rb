# frozen_string_literal: true

require "minitest/autorun"
require "indexmap"
require "timeout"
require "rbconfig"

class QueueChecks < Minitest::Test
  def setup
    IndexmapConfiguration.apply
    PublicPage.delete_all
    5.times { |id| PublicPage.create!(slug: "page-#{id}", published: true) }
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

  private

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
