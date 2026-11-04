# frozen_string_literal: true

module Indexmap
  class Validator
    class Duplicates
      def initialize(directory:)
        @directory = directory
        @buffer = []
        @runs = []
        @sequence = 0
      end

      def add(location)
        @buffer << location
        flush if @buffer.size == 10_000
      end

      def validate!
        previous = nil
        each_sorted_location do |line|
          raise ValidationError, "Duplicate sitemap URLs detected: #{line.chomp}" if line == previous

          previous = line
        end
      end

      def unique_count
        count = 0
        previous = nil
        each_sorted_location do |line|
          count += 1 unless line == previous
          previous = line
        end
        count
      end

      private

      def each_sorted_location
        flush unless @buffer.empty?
        while @runs.size > 1
          @runs = @runs.each_slice(2).map do |left, right|
            next left unless right

            target = next_path
            File.open(left) do |a|
              File.open(right) do |b|
                File.open(target, "wb") do |output|
                  x = a.gets
                  y = b.gets
                  while x || y
                    if y.nil? || (x && x <= y)
                      output.write(x)
                      x = a.gets
                    else
                      output.write(y)
                      y = b.gets
                    end
                  end
                end
              end
            end
            File.unlink(left, right)
            target
          end
        end
        File.foreach(@runs.first) { |line| yield line } if @runs.first
      end

      def flush
        path = next_path
        File.open(path, "wb") { |file| @buffer.sort.each { |location| file.puts(location) } }
        @runs << path
        @buffer.clear
      end

      def next_path
        @sequence += 1
        File.join(@directory, "urls-#{@sequence}")
      end
    end
  end
end
