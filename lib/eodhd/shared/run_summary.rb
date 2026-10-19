# frozen_string_literal: true

module Eodhd
  module Shared
    # Counts per-item outcomes of a run and reports failures at the end.
    #
    # Each item outcome is a Hash of kind => error message (nil on success).
    # Outcomes are plain data, so they can be returned from parallel worker processes.
    class RunSummary
      SAMPLE_ERROR_COUNT = 5

      def initialize(name:)
        @name = name
        @totals = Hash.new(0)
        @failures = Hash.new(0)
        @errors = []
      end

      def add(outcome)
        outcome.each do |kind, error|
          @totals[kind] += 1
          next if error.nil?

          @failures[kind] += 1
          @errors << error
        end
        self
      end

      def add_all(outcomes)
        outcomes.each { |outcome| add(outcome) }
        self
      end

      def failed?
        failure_count.positive?
      end

      def failure_count
        @errors.size
      end

      def total(kind)
        @totals[kind]
      end

      def failures(kind)
        @failures[kind]
      end

      def sample_errors
        @errors.first(SAMPLE_ERROR_COUNT)
      end

      def log(log)
        counts = @totals.keys.map { |kind| "#{kind} #{@failures[kind]} of #{@totals[kind]} failed" }
        counts_text = counts.empty? ? "nothing to do" : counts.join(", ")
        message = "Summary (#{@name}): #{counts_text}"

        unless failed?
          log.info(message)
          return
        end

        log.error(message)
        log.error("First #{sample_errors.size} of #{failure_count} error(s):")
        sample_errors.each { |error| log.error("  #{error}") }
      end
    end
  end
end
