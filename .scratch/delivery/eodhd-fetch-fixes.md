# Queue: trading-fetch-eodhd fetch and processing fixes

Branch: `fix-fetch-info-and-event-time-zone`. Mode: parallel (up to 4).
State: all items integrated; queue closed.

## 1. Fix `fetch info` calling removed Path methods

- Decision: pass the path function explicitly next to the API function; add a
  runner test.
- Footprint: `lib/eodhd/commands/fetch/subcommands/info/runner.rb`,
  `test/eodhd/commands/fetch/subcommands/info/runner_test.rb`.
- Depends on: none.
- Status: integrated (`df3e868`).

## 2. Events take effect at New York midnight, not the machine's local midnight

- Decision: add the `tzinfo` and `tzinfo-data` gems. Add one helper that turns
  a trading date into the Unix timestamp of midnight at the start of that date
  in the exchange's time zone (America/New_York for `us`, the only exchange
  fetched), with daylight saving. Replace every `Date#to_time.to_i` use with it:
  - `lib/eodhd/shared/parsing/eod_csv_parser.rb` (daily row timestamps);
  - `lib/eodhd/commands/process/shared/splits_processor.rb` (split moment);
  - `lib/eodhd/commands/process/shared/dividends_processor.rb` (ex-date moment
    and previous-close lookup);
  - the tests `splits_processor_test.rb` and `dividends_processor_test.rb`.
  Results must not depend on the machine's time zone; add a test that proves it
  under different `TZ` values. Include a regression case like CMG's 50:1 split
  on 2024-06-26: an intraday bar at 2024-06-25 22:00 UTC must be adjusted.
- Not in scope: which bar counts as the dividend "previous close" for intraday
  data (session topic C, undecided). With the new boundary it becomes the last
  bar before New York midnight.
- Not in scope: reprocessing existing data on the external drive.
- Footprint: `Gemfile`, `Gemfile.lock` (ignored), the three files above, a new
  helper file, their tests, possibly `README.md`.
- Depends on: 1.
- Status: integrated (`60d66c4`, `774a2d7`, `9858ef8`). Footprint miss: it
  also changed the `process eod` and `process intraday` runners (to pass the
  exchange), which item 4 also changes.

## 3. Intraday dividend factor uses the official daily close

- Decision: when processing intraday data, compute the dividend factor from
  the previous trading day's close in the raw daily file
  (`Path.raw_eod_file`, parsed with `EodCsvParser`), as daily processing
  already does, instead of from the last intraday bar before the ex-date.
  Daily and intraday data then get the same dividend factor.
- If a symbol has dividends but no raw daily file, fail that symbol with a
  clear error rather than falling back to intraday bars (confirmed by the
  user, C1a).
- Footprint: `lib/eodhd/commands/process/subcommands/intraday/runner.rb`,
  possibly `dividends_processor.rb`, their tests.
- Depends on: 2 (same files and the same day-boundary helper), 4 (both
  change `process/subcommands/intraday/runner.rb`).
- Status: integrated (`69a4e98`).

## 4. Count and report per-symbol failures

- Decision: in all six per-item runners (`fetch eod`, `fetch intraday`,
  `fetch info`, `fetch symbols`, `process eod`, `process intraday`), keep
  going after a failed item as now, but count the failures. At the end of the
  run, log a summary (failed count out of total, per kind where a runner has
  several, such as splits and dividends, plus the first few error messages),
  and exit with a nonzero status when anything failed. The existing immediate
  stop on `PaymentRequiredError` stays. Counting must work in parallel mode,
  which runs items in separate processes.
- Footprint: the six runners, `lib/util/parallel_executor.rb` if results must
  come back from processes, the `bin/` entry points or command layer for the
  exit status, tests.
- Depends on: 1 (same `fetch info` runner; integrated).
- Status: integrated (`909c2de`..`91a7176`, five commits, rebased onto item 2
  without conflicts).

## 5. Update stale `process meta` runner tests

- Decision: the runner's `process`, `get_daily_ranges` and
  `get_intraday_ranges` now require `parallel:` and `workers:`; update the six
  failing tests to pass them (sequential, plus parallel where a test already
  means parallel). Tests only; no runner change.
- Footprint: `test/eodhd/commands/process/subcommands/meta/runner_test.rb`.
- Depends on: none.
- Status: integrated (`ede4cca`). One test still fails: it expects an empty
  intraday boundary file to raise, but since `68111f0` the runner warns and
  skips the symbol (daily still raises). Resolved by item 6.

## 6. `process meta`: look inward past empty intraday edge files

- Decision (F5): when finding a symbol's intraday range, if the first month
  file has no data rows, try the next file, and so on, until one has data;
  likewise from the last file backward. Log a warning naming each empty file
  skipped. Count empty files in a run summary logged at the end of
  `process meta` (D1 style, `RunSummary`), and exit with status 1 if any were
  found. A symbol whose month files are all empty is left out of `meta.json`
  (warned and counted). Update the stale test to the new behavior and add tests
  for first-empty, last-empty and all-empty.
- Not in scope: daily ranges (an empty daily file still raises); writing files
  atomically (F4, not chosen).
- Footprint: `lib/eodhd/commands/process/subcommands/meta/runner.rb`,
  `lib/eodhd/commands/process.rb` (exit status), meta runner tests.
- Depends on: 4, 5 (integrated).
- Status: integrated (`9b35568`).

## 7. Document failure summaries and price adjustment rules in README

- Decision (L): note in `README.md` that commands exit with status 1 and log a
  summary when any item fails, and that splits and dividends take effect at
  exchange midnight in New York time.
- Status: integrated (`7f8fdcc`).
