# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "minitest/spec"
require "setup"

require_relative "test_util/data_driven"
require_relative "test_util/time_zone"
include TestSupport::DataDriven
include TestSupport::TimeZone
