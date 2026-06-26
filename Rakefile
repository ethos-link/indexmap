# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"
require_relative "lib/indexmap/version"

VERSION_PATH = File.expand_path("lib/indexmap/version.rb", __dir__)
VALID_RELEASE_TARGETS = %w[major minor patch].freeze

Rake::TestTask.new(:test) do |task|
  task.libs << "lib"
  task.libs << "test"
  task.test_files = FileList["test/**/*_test.rb"]
  task.warning = false
end

def current_branch
  `git branch --show-current`.strip
end

def clean_worktree?
  system("git diff --quiet") && system("git diff --cached --quiet")
end

def release_tag(version)
  "v#{version}"
end

def release_version(target)
  target = target.to_s.strip
  if target.empty?
    message = "Provide patch, minor, major, or an explicit X.Y.Z version."
    raise ArgumentError, message
  end

  return target if target.match?(/\A\d+\.\d+\.\d+\z/)

  unless VALID_RELEASE_TARGETS.include?(target)
    message = "Invalid release target #{target.inspect}. Use " \
      "#{VALID_RELEASE_TARGETS.join(", ")} or X.Y.Z."
    raise ArgumentError, message
  end

  major, minor, patch = Indexmap::VERSION.split(".").map(&:to_i)

  case target
  when "major"
    "#{major + 1}.0.0"
  when "minor"
    "#{major}.#{minor + 1}.0"
  when "patch"
    "#{major}.#{minor}.#{patch + 1}"
  end
end

def validate_release_version!(version, current)
  if Gem::Version.new(version) <= Gem::Version.new(current)
    message = "Release version #{version} must be newer than " \
      "current version #{current}."
    raise ArgumentError, message
  end

  tag = release_tag(version)
  if local_release_tag_exists?(tag)
    raise ArgumentError, "Release tag #{tag} already exists locally."
  end
  if remote_release_tag_exists?(tag)
    raise ArgumentError, "Release tag #{tag} already exists on origin."
  end
end

def local_release_tag_exists?(tag)
  system(
    "git",
    "rev-parse",
    "--quiet",
    "--verify",
    "refs/tags/#{tag}",
    out: File::NULL
  )
end

def remote_release_tag_exists?(tag)
  output = `#{remote_release_tag_command(tag)} 2>&1`
  status = $?

  if status.success?
    true
  elsif status.exitstatus == 2
    false
  else
    raise "Could not check origin for #{tag}: #{output.strip}"
  end
end

def remote_release_tag_command(tag)
  "git ls-remote --exit-code --tags origin refs/tags/#{tag}"
end

def update_version_file(version)
  File.write(
    VERSION_PATH,
    <<~RUBY
      # frozen_string_literal: true

      module Indexmap
        VERSION = "#{version}"
      end
    RUBY
  )
end

def changelog_command(version)
  [
    "git-cliff",
    "-c",
    "cliff.toml",
    "--unreleased",
    "--tag",
    release_tag(version),
    "--prepend",
    "CHANGELOG.md"
  ]
end

def update_changelog(version)
  success = system(*changelog_command(version))
  unless success
    message = "git-cliff failed. Install git-cliff and make sure " \
      "cliff.toml is valid."
    raise message
  end

  if system("git", "diff", "--quiet", "--", "CHANGELOG.md")
    message = "git-cliff did not update CHANGELOG.md. Ensure there are " \
      "Conventional Commits since the last tag."
    raise message
  end
end

if Rake::Task.task_defined?("release")
  Rake::Task["release"].clear
end

desc "Publishing is handled by CI. Use release:prepare[...] instead."
task :release do
  message = "Use `bundle exec rake 'release:prepare[patch]'` " \
    "(or minor/major/X.Y.Z). Publishing runs in GitHub Actions after " \
    "the tag is pushed."
  abort message
end

namespace :release do
  desc "Prepare a release: update changelog/version, commit, tag, and push."
  task :prepare, [:target] do |_task, args|
    branch = current_branch
    unless %w[main master].include?(branch)
      message = "Release must run on main or master. Current branch: " \
        "#{branch.inspect}."
      abort message
    end
    abort "Release requires a clean working tree." unless clean_worktree?

    version = release_version(args[:target])
    current = Indexmap::VERSION
    validate_release_version!(version, current)

    update_changelog(version)
    update_version_file(version)

    tag = release_tag(version)

    sh "git add CHANGELOG.md lib/indexmap/version.rb"
    sh %(LEFTHOOK=0 git commit -m "chore(release): prepare v#{version}")
    sh %(git tag -a #{tag} -m "Release #{tag}")
    sh "git push origin #{branch}"
    sh "git push origin #{tag}"
  rescue ArgumentError, RuntimeError => e
    abort e.message
  end
end

task default: %i[test standard]
