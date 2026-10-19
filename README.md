# Trading - Fetch EODHD

This is a collection of Ruby scripts used to fetch trading data from [EOD Historical Data](https://eodhistoricaldata.com/) and for processing it.

## Project Setup

### 1. Install Ruby

Confirm mise is installed and install the Ruby version declared in `.mise.toml`:

```bash
mise --version
mise install
```

Verify:

```bash
mise exec -- ruby -v
```

### 2. Install Gems

```bash
mise exec -- bundle install
```

Or if you have mise shell activation enabled:

```bash
bundle install
```

### 3. Make Scripts Executable

```bash
chmod +x bin/*
```

### 4. Setup Environment Variables

Copy the example env file and configure it:

```bash
cp .env.example .env
```

Edit `.env` and set your EODHD API key and any other necessary variables.

### 5. Using External Drive for Data (Optional)

```bash
sudo mount -t exfat -o uid=$(id -u),gid=$(id -g) /dev/disk/by-uuid/34D4-9F99 /home/mrzli/projects/ext
```

To unmount:

```bash
sync
sudo umount /home/mrzli/projects/ext
```

## Updating Dependencies

The Ruby version is pinned exactly in `.mise.toml`, and gem versions are pinned in `Gemfile.lock` (the `Gemfile` lists gems without versions). Both change only when you update them:

```bash
mise use --pin ruby@latest   # newest Ruby, written to .mise.toml as an exact version
bundle update                # newest gems, written to Gemfile.lock
rake test
```

`bundle outdated` lists available updates without changing anything. If an update breaks something, restore `Gemfile.lock` from Git and update gems one at a time with `bundle update <gem>`.

## Running Commands

All commands support `--help` flag to show usage information.

Commands that work through many symbols (`fetch symbols`, `fetch info`, `fetch eod`, `fetch intraday`, `process eod`, `process intraday`, `process meta`) keep going when one symbol fails, log a warning for it, and end with a summary of failures per kind with the first few error messages. They exit with status 1 if any item failed, so check the exit status or the summary after a run. HTTP 402 (payment required) from the API still stops a fetch immediately.

### Fetch Data

Fetches data from EODHD API.

```bash
./bin/fetch --help                           # Show help

# Fetch exchanges list
./bin/fetch exchanges          # Fetch exchanges
./bin/fetch exchanges --force  # Force fresh fetch

# Fetch symbols for exchanges
./bin/fetch symbols            # Fetch symbols (sequentially)
./bin/fetch symbols --parallel # Fetch symbols (parallel with default workers)
./bin/fetch symbols -p -w 8    # Fetch symbols (parallel with 8 workers)
./bin/fetch symbols -f -p      # Force fetch symbols in parallel

# Fetch info (splits and dividends)
./bin/fetch info               # Fetch info (sequentially)
./bin/fetch info --parallel    # Fetch info (parallel with default workers)
./bin/fetch info -p -w 8       # Fetch info (parallel with 8 workers)
./bin/fetch info -f -p         # Force fetch info in parallel

# Fetch EOD (end-of-day) data
./bin/fetch eod                # Fetch EOD (sequentially)
./bin/fetch eod --parallel     # Fetch EOD (parallel with default workers)
./bin/fetch eod -p -w 8        # Fetch EOD (parallel with 8 workers)
./bin/fetch eod -f -p          # Force fetch EOD in parallel

# Fetch intraday data
./bin/fetch intraday                  # Fetch intraday (sequentially)
./bin/fetch intraday --parallel       # Fetch intraday (parallel with default workers)
./bin/fetch intraday -p -w 8          # Fetch intraday (parallel with 8 workers)
./bin/fetch intraday --recheck-start-date -p  # Recheck from start date
./bin/fetch intraday --unfetched-only -p      # Fetch only symbols with no processed intraday files
```

### Process Data

Processes fetched data (splits, dividends, price adjustments, merging).

```bash
./bin/process --help              # Show help

# Process EOD data
./bin/process eod                 # Process EOD data (sequentially)
./bin/process eod --parallel      # Process EOD data (parallel)
./bin/process eod -p -w 8         # Process EOD data (parallel with 8 workers)
./bin/process eod -f -p           # Force process EOD data in parallel

# Process intraday data
./bin/process intraday            # Process intraday data (sequentially)
./bin/process intraday --parallel # Process intraday data (parallel)
./bin/process intraday -p -w 8    # Process intraday data (parallel with 8 workers)
./bin/process intraday -f -p      # Force process intraday data in parallel

# Build output metadata summary
./bin/process meta                # Generate meta.json summary from processed data
./bin/process meta -p             # Generate metadata summary in parallel
./bin/process meta -p -w 8        # Generate metadata summary in parallel with 8 workers
```

### Clean Data

Removes fetched/processed data.

```bash
./bin/clean --help       # Show help

# Clean exchanges data
./bin/clean exchanges    # Delete exchanges list (with confirmation)
./bin/clean exchanges -y # Delete exchanges list (skip confirmation)

# Clean symbols data
./bin/clean symbols      # Delete symbols (with confirmation)
./bin/clean symbols -y   # Delete symbols (skip confirmation)

# Other clean targets
./bin/clean info         # Delete info directory
./bin/clean raw          # Delete raw directory
./bin/clean raw-eod      # Delete raw/eod directory
./bin/clean raw-intraday # Delete raw/intraday directory
./bin/clean data         # Delete data directory
./bin/clean data-eod     # Delete data/eod directory
./bin/clean data-intraday # Delete data/intraday directory
./bin/clean log          # Delete log directory

# Dry run (show target without deleting)
./bin/clean data -n
```

## Architecture

### Directory Structure

- `bin/`: Command-line entry points (fetch, process, clean)
- `lib/`: Core library code
  - `eodhd/`: Main application namespace
    - `args/`: Shared argument parsing utilities
    - `commands/`: Top-level command implementations
      - `fetch/`: Data fetching logic
        - `subcommands/`: Fetch subcommands (exchanges, symbols, info, eod, intraday)
      - `process/`: Data processing logic
        - `subcommands/`: Process subcommands (eod, intraday, meta)
        - `shared/`: Processing utilities (splits, dividends, price adjustments)
      - `clean/`: Data cleaning logic
    - `shared/`: Shared utilities across commands
      - `parsing/`: CSV and JSON parsers
      - `processing/`: Data processing components
  - `logging/`: Logging infrastructure (console, file, null sinks)
  - `util/`: General utilities (date, string, validation, binary search, parallel execution)
- `test/`: Test suite mirroring `lib/` structure
- `docs/`: Project documentation

### Key Components

- **Dependency Injection**: Uses `Eodhd::Shared::Container` for IoC
- **Configuration**: Environment-based configuration via `.env` file
- **Logging**: Structured logging with multiple sink support (console, file)
- **Parallel Processing**: Configurable worker-based parallel execution for fetch/process operations
- **Data Parsing**: Specialized parsers for CSV (EOD, intraday) and JSON (splits, dividends)
- **Autoloading**: Uses Zeitwerk for automatic code loading based on file structure

### Output Directory Structure

The project organizes fetched and processed data in the following structure (rooted at `OUTPUT_DIR` from `.env`):

```
{OUTPUT_DIR}/
├── data/                                   # Processed data (adjusted for splits/dividends)
│   ├── eod/                                # Processed end-of-day data
│   │   └── {exchange}/
│   │       └── {symbol}.csv                # Adjusted EOD prices
│   └── intraday/                           # Processed intraday data
│       └── {exchange}/
│           └── {symbol}/
│               └── {year}-{month}.csv      # Adjusted monthly intraday data
├── info/                                   # Splits and dividends data
│   └── {exchange}/
│       └── {symbol}/
│           └── dividends.json              # Dividend history
│           └── splits.json                 # Stock split history
├── log/                                    # Application logs
├── raw/                                    # Raw fetched data
│   ├── eod/                                # Raw end-of-day data
│   │   └── {exchange}/
│   │       └── {symbol}.csv                # Raw EOD prices (unadjusted)
│   └── intraday/                           # Raw intraday data
│       ├── fetched/                        # Fetched intraday data
│       │   └── {exchange}/
│       │       └── {symbol}/
│       │           └── {from}___{to}.csv   # Raw intraday data for date range
│       └── processed/                      # Merged intraday data
│           └── {exchange}/
│               └── {symbol}/
│                   └── {year}-{month}.csv  # Merged monthly intraday data
├── symbols/                                # Symbol lists by exchange
│   └── {exchange}/
│       └── {type}.json                     # Symbols grouped by type (stocks, etfs, etc.)
├── exchanges.json                          # List of all available exchanges
└── meta.json                               # Summary per symbol/exchange with daily/intraday data ranges
```

**Key differences:**

- `raw/`: Unprocessed data as fetched from EODHD API
- `data/`: Processed data with splits/dividends adjustments applied

### Price Adjustments

- A split or dividend takes effect at midnight at the start of its date in the exchange's time zone (America/New_York for `us`), independent of the machine's time zone. Rows (daily rows and intraday bars) before that moment are adjusted; intraday bars from the previous evening session are therefore adjusted too.
- The dividend multiplier is `(previous close - dividend) / previous close`, using the previous trading day's official close from `raw/eod`. Daily and intraday data use the same multiplier, so `process intraday` needs the raw daily file for any symbol that has dividends, and fails that symbol if it is missing.
- `process meta` takes each symbol's intraday range from its first and last month files that contain data. Empty month files at either end are skipped with a warning and reported as failures.
