# frozen_string_literal: true

require "json"

module Eodhd
  module Commands
    module Fetch
      module_function

      def run
        container = Eodhd::Shared::Container.new(command: "fetch")
        runner = Runner.new(container: container)
        fetch_args_parser = Eodhd::Args::SubcommandsArgs.new(
          container: container,
          command_name: "fetch",
          valid_subcommands: %w[exchanges symbols info eod intraday]
        )

        subcommand, = fetch_args_parser.parse(ARGV).deconstruct

        # Set by subcommands that process many items and may fail for some of them.
        summary = nil

        case subcommand
        when "exchanges"
          args_parser = Subcommands::Exchanges::Args.new(container: container)
          force, = args_parser.parse(ARGV).deconstruct
          runner.exchanges(force: force)
        when "symbols"
          args_parser = Subcommands::Symbols::Args.new(container: container)
          force, parallel, workers = args_parser.parse(ARGV).deconstruct
          summary = runner.symbols(force: force, parallel: parallel, workers: workers)
        when "info"
          args_parser = Subcommands::Info::Args.new(container: container)
          force, parallel, workers = args_parser.parse(ARGV).deconstruct
          summary = runner.info(force: force, parallel: parallel, workers: workers)
        when "eod"
          args_parser = Subcommands::Eod::Args.new(container: container)
          force, parallel, workers = args_parser.parse(ARGV).deconstruct
          summary = runner.eod(force: force, parallel: parallel, workers: workers)
        when "intraday"
          args_parser = Subcommands::Intraday::Args.new(container: container)
          recheck_start_date, unfetched_only, parallel, workers = args_parser.parse(ARGV).deconstruct
          summary = runner.intraday(
            recheck_start_date: recheck_start_date,
            unfetched_only: unfetched_only,
            parallel: parallel,
            workers: workers
          )
        else
          raise "Unknown subcommand: #{subcommand}"
        end

        exit(1) if summary&.failed?
      rescue Eodhd::Shared::Api::PaymentRequiredError => e
        container.logger.error("Received HTTP 402 from API. Exiting fetch execution.")
        container.logger.error(e.message)
        exit(1)
      end
    end
  end
end
