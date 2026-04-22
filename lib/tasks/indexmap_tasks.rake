namespace :sitemap do
  desc "Create sitemap files"
  task create: :environment do
    runner = Indexmap::TaskRunner.new
    create_result = runner.create
    runner.format
    validated_files = runner.validate

    puts "Created, formatted, and validated #{file_count(validated_files)} in #{public_directory(runner)}."
    puts "IndexNow key file: #{create_result[:index_now_key_path]}" if create_result[:index_now_key_path]
  end

  desc "Format sitemap files for better readability"
  task format: :environment do
    runner = Indexmap::TaskRunner.new
    formatted_files = runner.format

    puts "Formatted #{file_count(formatted_files)} in #{public_directory(runner)}."
  end

  desc "Validate sitemap shape and URL hygiene"
  task validate: :environment do
    runner = Indexmap::TaskRunner.new
    validated_files = runner.validate

    puts "Validated #{file_count(validated_files)} for sitemap shape and URL hygiene."
  end

  desc "Ping all configured search engines"
  task ping: :environment do
    Rake::Task["sitemap:index_now:ping"].invoke
    Rake::Task["sitemap:google:ping"].invoke
  end

  namespace :google do
    desc "Ping Google Search Console"
    task ping: :environment do
      Indexmap::Pinger::Google.new.ping
    end
  end

  namespace :index_now do
    desc "Ping IndexNow. ENV: SINCE=2026-04-18T10:30:00Z or INDEXNOW_RECENT_HOURS=24"
    task ping: :environment do
      Indexmap::Pinger::IndexNow.new.ping
    end

    desc "Ensure the IndexNow key file exists in public/"
    task write_key: :environment do
      path = Indexmap::TaskRunner.new.write_index_now_key(generate_if_missing: true)
      if path
        puts "IndexNow key file available at #{path}."
      else
        puts "IndexNow key is not configured; skipped key file write."
      end
    end
  end

  def file_count(files)
    count = Array(files).size
    "#{count} sitemap #{(count == 1) ? "file" : "files"}"
  end

  def public_directory(runner)
    runner.public_path
  end
end
