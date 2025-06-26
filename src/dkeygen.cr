require "log"
require "yaml"
require "colorize"

class String
  def colorize(hex : String) : Colorize::Object
    hex = hex.lstrip('#')
    raise ArgumentError.new("Invalid hex color") unless hex =~ /^[0-9a-f]{6}$/i

    self.colorize(Colorize::ColorRGB.new(hex[0..1].to_u8(16),
      hex[2..3].to_u8(16),
      hex[4..5].to_u8(16)))
  end
end

SHARD = YAML.parse {{ read_file("#{__DIR__}/../shard.yml") }}

struct DefaultFormatter < Log::StaticFormatter
  @@colors = {
    "TRACE":  :white,
    "DEBUG":  :light_blue,
    "INFO":   :green,
    "NOTICE": :white,
    "WARN":   :yellow,
    "ERROR":  :red,
    "FATAL":  :light_red,
  }

  def run
    # timestamp
    # string " "
    string "["
    string @entry.severity.label.center(7).colorize(@@colors[@entry.severity.label])
    string "]"
    string " |"
    source
    string "| "
    message
  end
end

Log.setup_from_env(backend: Log::IOBackend.new(formatter: DefaultFormatter))

module Dkeygen
  VERSION = SHARD["version"]
  Log     = ::Log.for(SHARD["name"].to_s)
  Log.debug { "v#{VERSION} (Crystal #{Crystal::VERSION})" }

  module TerminationHandler
    @@handler_called = Atomic(Bool).new(false)

    def self.cleanup
      return if @@handler_called.swap(true)
      CliCommonLogic::Tempdir.cleanup_all_tempdirs
    end

    def self.setup
      [Signal::HUP, Signal::INT, Signal::TERM, Signal::QUIT].each do |sig|
        sig.trap do
          Log.error { "Received #{sig}, terminating..." }
          cleanup
          exit(128 + sig.value)
        end
      end
      at_exit { cleanup }
    end
  end
end

Dkeygen::TerminationHandler.setup
require "./dkeygen/cli"
