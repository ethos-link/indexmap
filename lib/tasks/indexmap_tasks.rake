namespace :indexmap do
  namespace :sitemap do
    desc "Create sitemap files"
    task create: :environment do
      runner = Indexmap::TaskRunner.new
      create_result = runner.create

      puts "Created, formatted, and validated #{file_count(create_result[:files])} in #{public_directory(runner)}."
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
  end

  desc "Ping all configured search engines"
  task ping: :environment do
    Rake::Task["indexmap:index_now:ping"].invoke
    Rake::Task["indexmap:google:ping"].invoke
  end

  namespace :google do
    desc "Ping Google Search Console"
    task ping: :environment do
      result = Indexmap::Pinger::Google.new.ping

      case result[:status]
      when :submitted
        puts "Submitted #{result[:sitemap_count]} sitemap #{(result[:sitemap_count] == 1) ? "file" : "files"} with #{result[:url_count]} URL#{"s" unless result[:url_count] == 1} to Google Search Console."
      when :partial
        puts "Submitted #{result[:sitemap_count]} sitemap #{(result[:sitemap_count] == 1) ? "file" : "files"} with #{result[:url_count]} URL#{"s" unless result[:url_count] == 1} to Google Search Console, with #{result[:failures].count} failure#{"s" unless result[:failures].count == 1}."
        result[:failures].each { |failure| puts format_google_ping_failure(failure) }
      when :failed
        result[:failures].each { |failure| puts format_google_ping_failure(failure) }
      when :skipped
        puts format_google_ping_skip(result)
      end
    end
  end

  namespace :index_now do
    desc "Ping IndexNow. ENV: SINCE=2026-04-18T10:30:00Z or INDEXNOW_RECENT_HOURS=24"
    task ping: :environment do
      result = Indexmap::Pinger::IndexNow.new.ping

      case result[:status]
      when :submitted
        puts "Submitted #{result[:url_count]} URL#{"s" unless result[:url_count] == 1} to IndexNow in #{result[:batch_count]} request#{"s" unless result[:batch_count] == 1}."
      when :partial
        puts "Submitted #{result[:url_count]} URL#{"s" unless result[:url_count] == 1} to IndexNow in #{result[:batch_count]} request#{"s" unless result[:batch_count] == 1}, with #{result[:failures].count} failure#{"s" unless result[:failures].count == 1}."
        result[:failures].each { |failure| puts format_index_now_ping_failure(failure) }
      when :failed
        result[:failures].each { |failure| puts format_index_now_ping_failure(failure) }
      when :dry_run
        puts "IndexNow dry-run: would submit #{result[:url_count]} URL#{"s" unless result[:url_count] == 1} in #{result[:batch_count]} request#{"s" unless result[:batch_count] == 1}."
      when :skipped
        puts format_index_now_ping_skip(result)
      end
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

  def format_google_ping_failure(failure)
    case failure[:reason]
    when :unauthorized
      "Google Search Console does not have access to #{failure[:property]}."
    when :client_error
      "Google ping failed for #{failure[:sitemap_url]} (status #{failure[:status_code]})."
    else
      "Google ping failed."
    end
  end

  def format_google_ping_skip(result)
    case result[:reason]
    when :missing_credentials
      "Google sitemap credentials are not configured; skipped Google submission."
    when :no_sitemaps
      "No sitemap files found; skipped Google submission."
    else
      "Skipped Google submission."
    end
  end

  def format_index_now_ping_failure(failure)
    case failure[:status_code]
    when nil
      "IndexNow submission failed."
    else
      "IndexNow submission failed for #{failure[:url_count]} URL#{"s" unless failure[:url_count] == 1} (status #{failure[:status_code]})."
    end
  end

  def format_index_now_ping_skip(result)
    case result[:reason]
    when :missing_key
      "IndexNow key is not configured and no valid key file was found; skipped IndexNow submission."
    when :no_urls
      "No sitemap URLs matched the current IndexNow filter; skipped IndexNow submission."
    else
      "Skipped IndexNow submission."
    end
  end
end
