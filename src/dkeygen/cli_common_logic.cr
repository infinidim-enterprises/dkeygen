require "uuid"
require "file_utils"
require "digest/sha256"

module Dkeygen
  module CliCommonLogic
    Log = ::Log.for(self)

    class Bip39key
      include CliCommonLogic
      Log = ::Log.for(self)

      WORDLIST_BIP39 = {{ read_file("#{__DIR__}/../resources/bip39_english.txt") }}.split(/[ \n]+/).reject(&.empty?)

      enum BIP39Length
        Words12 = 12
        Words15 = 15
        Words18 = 18
        Words21 = 21
        Words24 = 24

        def bits : Int
          case self
          when BIP39Length::Words12 then 128
          when BIP39Length::Words15 then 160
          when BIP39Length::Words18 then 192
          when BIP39Length::Words21 then 224
          when BIP39Length::Words24 then 256
          else
            raise "Unhandled BIP39 length: #{self}"
          end
        end

        def self.valid?(length : Int) : Bool
          values.map(&.value).includes?(length)
        end

        def self.words(count : Int) : Int
          from_value?(count).try &.bits || raise ArgumentError.new("Invalid BIP39 word count: #{count}")
        end
      end

      property key_filename : String?
      property working_dir : Path
      property seed : Array(String)?
      property seed_file : (String | Path)?
      property cmd_dump : Dump

      def initialize(@cmd_dump : Dump,
                     @seed_file = nil,
                     mnemonic_size : Int = 24)
        @working_dir = @cmd_dump.working_dir.path
        @seed = if @cmd_dump.key_config.user.try &.mnemonic
                  read_mnemonic(@cmd_dump.key_config.user.mnemonic.to_s)
                elsif seed_path = @seed_file
                  read_mnemonic(File.read(seed_path)) if File.exists?(seed_path) && File::Info.readable?(seed_path)
                else
                  generate_mnemonic(mnemonic_size)
                end

        unless seed_path = @seed_file
          @seed_file = (@working_dir / "seed.txt").to_s
          if seed = @seed
            Log.trace { "#{@seed_file.inspect}" }
            Log.trace { "#{seed.inspect}" }
            File.write(@seed_file.not_nil!, (seed.join(" ") + "\n"))
          end
        end

        @key_filename = (@working_dir / "private_key.asc").to_s
        Log.debug { "#{@key_filename.inspect}" }
        gpg_key_create
      end

      private def generate_mnemonic(word_count : Int) : Array(String)
        unless BIP39Length.valid?(word_count)
          raise ArgumentError.new("Invalid word count. Allowed values: 12, 15, 18, 21, 24")
        end

        entropy_bits = BIP39Length.words(word_count)
        entropy_bytes = (entropy_bits / 8).to_i16
        entropy = Random::Secure.random_bytes(entropy_bytes)
        checksum_length = (entropy_bits / 32).to_i16
        hash = Digest::SHA256.digest(entropy)
        entropy_bits_str = bytes_to_bits(entropy)
        hash_bits_str = bytes_to_bits(hash)
        checksum_bits_str = hash_bits_str[0, checksum_length]
        bits = entropy_bits_str + checksum_bits_str

        words = [] of String
        (0...(bits.size / 11)).each do |i|
          segment = bits[(i * 11)...(i * 11 + 11)]
          index = segment.to_i(2)
          words << WORDLIST_BIP39[index]
        end

        words
      end

      private def bytes_to_bits(bytes : Bytes) : String
        bits = String.build do |str|
          bytes.each do |b|
            str << b.to_s(2).rjust(8, '0')
          end
        end
        bits
      end

      private def gpg_key_create
        Log.debug { "💡 gpg_key_create start" }
        uid = ["#{self.cmd_dump.key_config.user.first_name}",
               "#{self.cmd_dump.key_config.user.last_name}",
               "<#{self.cmd_dump.key_config.user.email}>"].reject(&.empty?)

        args = ["--user-id",
                "'#{uid.join(" ")}'",
                "--input-filename",
                "#{self.seed_file}",
                "--output-filename",
                "#{self.key_filename}"].concat(self.cmd_dump.key_config.bip39key.args)

        Log.debug { "#{args.inspect}" }

        binary_check_and_run(self.cmd_dump.bip39key,
          "bip39key",
          args,
          self.cmd_dump.env_vars) do |_|
          Log.debug { "#{"✓".colorize(:green)} gpg_key_create" }
          self.cmd_dump.report.mnemonic = self.seed
          self.cmd_dump.pb_tick("Generated new key")
        end
      end

      private def full_seed_from_partial(seed : Array(String)) : Array(String)
        unless BIP39Length.valid?(seed.size)
          Log.error { "#{seed.size} is not a valid seed length! Must be one of #{BIP39Length.values.map(&.value).join(" ")}" }
          exit 1
        end

        Log.debug { "#{seed.inspect}" }

        seed.map do |partial_word|
          full_word = WORDLIST_BIP39.find(&.starts_with?(partial_word))
          Log.debug { "partial_word: #{partial_word.inspect} [#{partial_word.size}], full_word: #{full_word.inspect}" }
          unless partial_word.size >= 3 && full_word
            Log.error { "#{partial_word} is either not part of an English BIP39 or is less than 3 chars!" }
            exit(1)
          end
          full_word
        end
      end

      private def read_mnemonic(str : String) : Array(String)
        full_seed_from_partial(str.split(/[ \n]+/).reject(&.empty?))
      end
    end

    class Tempdir
      @@instances = [] of Tempdir
      @@log = ::Log.for(self)

      property path : Path

      forward_missing_to @path

      def initialize(prefix : String | Nil = nil)
        @path = Path.new(Dir.tempdir) / (prefix ? prefix.to_s + "-" + UUID.random.to_s : UUID.random.to_s)
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

    def binary_check_and_run(binary_path : String?,
                             name : String,
                             args : Array(String),
                             env : Process::Env = nil,
                             &success_block : (String) -> Nil)
      unless binary_path
        Log.error { "#{name} binary not found in PATH!" }
        exit(1)
      end

      Log.trace { "#{binary_path} - binary found" }
      res = Expect.none_interactive_process binary_path.to_s, args, env

      unless res[:status].success?
        Log.error { "#{binary_path} #{args.join(" ")} - Failed to run" }
        exit(1)
      end
      success_block.call(res[:output])
    end

    # def on_missing_arguments(arguments : Array(String))
    #   puts "#{@name}: argument missing: [#{arguments.join(", ")}]"
    #   puts help_template
    #   exit_program(1)
    # end

  end
end
