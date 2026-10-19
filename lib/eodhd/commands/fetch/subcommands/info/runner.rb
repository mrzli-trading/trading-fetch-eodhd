# frozen_string_literal: true

module Eodhd
  module Commands
    module Fetch
      module Subcommands
        module Info
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

              fetch_info_for_symbols(filtered_entries, force: force, parallel: parallel, workers: workers)
            end

            private

            def fetch_info_for_symbols(symbol_entries, force:, parallel:, workers:)
              outcomes = Util::ParallelExecutor.map(symbol_entries, parallel: parallel, workers: workers) do |entry|
                fetch_single(entry, force: force)
              end

              summary = Eodhd::Shared::RunSummary.new(name: "fetch info").add_all(outcomes)
              summary.log(@log)
              summary
            end

            def fetch_single(symbol_entry, force:)
              threads = [
                Thread.new do
                  fetch_info(
                    symbol_entry,
                    :splits,
                    ->(e, s) { Eodhd::Shared::Path.splits_file(e, s) },
                    ->(e, s) { @api.get_splits_json(e, s) },
                    force: force
                  )
                end,
                Thread.new do
                  fetch_info(
                    symbol_entry,
                    :dividends,
                    ->(e, s) { Eodhd::Shared::Path.dividends_file(e, s) },
                    ->(e, s) { @api.get_dividends_json(e, s) },
                    force: force
                  )
                end
              ]
              splits_error, dividends_error = threads.map(&:value)
              { splits: splits_error, dividends: dividends_error }
            end

            # Returns nil on success or skip, or the failure message.
            def fetch_info(symbol_entry, type, path_method, api_method, force:)
              exchange = symbol_entry[:exchange]
              symbol = symbol_entry[:symbol]
              exchange_symbol = "#{exchange}/#{symbol}"

              path = path_method.call(exchange, symbol)
              unless force || @shared.file_stale?(path)
                @log.info("[#{exchange_symbol}] Skipping #{type} (fresh): #{path}")
                return nil
              end

              @log.info("[#{exchange_symbol}] Fetching #{type} JSON#{force ? ' (forced)' : ''}...")
              data = api_method.call(exchange, symbol)
              @io.write_json(path, data, true)
              @log.info("[#{exchange_symbol}] Wrote #{path}")
              nil
            rescue StandardError => e
              raise if e.is_a?(Eodhd::Shared::Api::PaymentRequiredError)

              message = "[#{exchange_symbol}] Failed #{type}: #{e.class}: #{e.message}"
              @log.warn(message)
              message
            end

          end
        end
      end
    end
  end
end
