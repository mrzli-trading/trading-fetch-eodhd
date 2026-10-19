# frozen_string_literal: true

module Eodhd
  module Commands
    module Fetch
      module Subcommands
        module Eod
          class Runner

            def initialize(container:, shared:)
              @log = container.logger
              @api = container.api
              @io = container.io
              @data_reader = container.data_reader

              @shared = shared
            end

            def fetch(force:, parallel:, workers:)
              symbol_entries = @data_reader.symbols
              filtered_entries = symbol_entries.filter { |entry| @shared.should_fetch_symbol?(entry) }

              fetch_eod_for_symbols(filtered_entries, force: force, parallel: parallel, workers: workers)
            end

            private

            def fetch_eod_for_symbols(symbol_entries, force:, parallel:, workers:)
              outcomes = Util::ParallelExecutor.map(symbol_entries, parallel: parallel, workers: workers) do |entry|
                { eod: fetch_single(entry, force: force) }
              end

              summary = Eodhd::Shared::RunSummary.new(name: "fetch eod").add_all(outcomes)
              summary.log(@log)
              summary
            end

            # Returns nil on success or skip, or the failure message.
            def fetch_single(symbol_entry, force:)
              exchange = symbol_entry[:exchange]
              type = symbol_entry[:type]
              symbol = symbol_entry[:symbol]

              exchange_symbol = "#{exchange}/#{symbol}"
              relative_path = Eodhd::Shared::Path.raw_eod_file(exchange, symbol)

              unless force || @shared.file_stale?(relative_path)
                @log.info("[#{exchange_symbol}] Skipping EOD (fresh): #{relative_path}")
                return nil
              end

              begin
                @log.info("[#{exchange_symbol}] Fetching EOD CSV (#{type})#{force ? ' (forced)' : ''}...")
                csv = @api.get_eod_data_csv(exchange, symbol)
                @io.write_csv(relative_path, csv)
                @log.info("[#{exchange_symbol}] Wrote #{relative_path}")
                nil
              rescue StandardError => e
                raise if e.is_a?(Eodhd::Shared::Api::PaymentRequiredError)

                message = "[#{exchange_symbol}] Failed EOD: #{e.class}: #{e.message}"
                @log.warn(message)
                message
              end
            end
          end
        end
      end
    end
  end
end
