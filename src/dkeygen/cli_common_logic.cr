require "uuid"
require "file_utils"

module Dkeygen
  module CliCommonLogic
    Log = ::Log.for(self)

    class Bip39key
      WORDLIST_BIP39 = {{ read_file("#{__DIR__}/../resources/bip39_english.txt") }}

      def full_seed_from_partial
        full_seed = SEED.flat_map do |partial_word|
          prefix = partial_word[0..3]
          WORDLIST_BIP39.select do |full_word|
            full_word.starts_with?(prefix)
          end
        end
      end

      def bip39key
        if Process.find_executable "bip39key"
          puts "found"
        else
          puts "not found"
        end
      end
    end

    class Tempdir
      @@instances = [] of Tempdir
      @@log = ::Log.for(self)

      property path : Path

      forward_missing_to @path

      def initialize(prefix : String | Nil = nil)
        puts prefix if prefix
        @path = Path.new File.join Dir.tempdir, prefix ? prefix.to_s + "-" + UUID.random.to_s : UUID.random.to_s
        _create_directory
        @@instances << self
        @@log.trace { "Created: #{@path}" }
      end

      def exists?
        File.exists?(@path)
      end

      def /(other : Path | String) : Path
        target = @path / other
        Dir.mkdir_p(target)
        @@log.trace { "Created: #{target}" }
        target
      end

      def delete
        FileUtils.rm_rf @path
        @@instances.delete(self)
        @@log.trace { "Deleted #{@path}" }
      end

      private def _create_directory
        Dir.mkdir_p(@path)
      end

      def self.cleanup_all_tempdirs
        @@log.trace { "Initiating cleanup of all Tempdir instances..." }
        @@instances.dup.each do |temp_dir|
          begin
            temp_dir.delete
          rescue ex
            @@log.error { "Error deleting Tempdir #{temp_dir.path}: #{ex.message}" }
          end
        end
        @@log.trace { "Finished cleanup of Tempdir instances." }
      end
    end

    module Helper
      extend self

      def ask(prompt : String, default : Bool? = nil) : Bool
        suffix = case default
                 when true  then " [Y/n]"
                 when false then " [y/N]"
                 else            " [y/n]"
                 end

        loop do
          print "#{prompt}#{suffix} "
          input = gets.try &.strip.downcase

          case input
          when "y", "yes" then return true
          when "n", "no"  then return false
          when "", nil
            return default if default != nil
          end
        end
      end
    end

    def pre_run(arguments : Cling::Arguments, options : Cling::Options) : Nil
      if condition_show_help arguments, options
        puts help_template
        return true
      end

      super_result = super(arguments, options)
      super_result.nil? ? true : super_result
    end

    private def condition_show_help(arguments : Cling::Arguments, options : Cling::Options) : Bool
      parent_cmd = @parent
      ((options.has? "help") || !parent_cmd) && !options.has? "version"
    end

    # def on_missing_arguments(arguments : Array(String))
    #   puts "#{@name}: argument missing: [#{arguments.join(", ")}]"
    #   puts help_template
    #   exit_program(1)
    # end

  end
end
