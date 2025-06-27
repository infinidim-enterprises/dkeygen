require "cling"
require "colorize"
require "progress_bar.cr/progress_bar"
require "cronic"

require "./cli_common_logic"
require "./config_yaml"
require "./expect"
require "./gpg_key"
require "./gpg_agent"
require "./cli_cmd_dump"

module Dkeygen
  class Cli < Cling::Command
    include CliCommonLogic

    def setup : Nil
      @name = "dkeygen"
      @description = "Create and/or dump gpg keys to a hardware token"
      add_option 'h', "help", description: "Show usage"
      add_option 'v', "version", description: "Show version"
    end

    def run(arguments : Cling::Arguments, options : Cling::Options) : Nil
      if options.has? "version"
        puts "#{SHARD["name"]} v#{VERSION}"
        return false
      end
    end
  end
end

cli = Dkeygen::Cli.new
cli.add_command Dkeygen::Dump.new

cli.execute ARGV
