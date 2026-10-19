# frozen_string_literal: true

require "json"

module Eodhd
  module Commands
    module Process
      module_function

      def run
        container = Eodhd::Shared::Container.new(command: "process")
        runner = Runner.new(container: container)
        process_args_parser = Eodhd::Args::SubcommandsArgs.new(
          container: container,
          command_name: "process",
          valid_subcommands: %w[eod intraday meta]
        )

        subcommand, = process_args_parser.parse(ARGV).deconstruct

        # Set by subcommands that process many items and may fail for some of them.
        summary = nil

        case subcommand
        when "eod"
          args_parser = Subcommands::Eod::Args.new(container: container)
          force, parallel, workers = args_parser.parse(ARGV).deconstruct
          summary = runner.eod(force: force, parallel: parallel, workers: workers)
        when "intraday"
          args_parser = Subcommands::Intraday::Args.new(container: container)
          force, parallel, workers = args_parser.parse(ARGV).deconstruct
          summary = runner.intraday(force: force, parallel: parallel, workers: workers)
        when "meta"
          args_parser = Subcommands::Meta::Args.new(container: container)
          parallel, workers = args_parser.parse(ARGV).deconstruct
          summary = runner.meta(parallel: parallel, workers: workers)
        else
          raise "Unknown subcommand: #{subcommand}"
        end

        exit(1) if summary&.failed?
      end
    end
  end
end
