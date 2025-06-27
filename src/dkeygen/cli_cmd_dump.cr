require "syscall"
require "./report"

module Dkeygen
  Syscall.def_syscall geteuid, Int32

  class Dump < Cling::Command
    include CliCommonLogic
    Log = ::Log.for(self)

    property gpg_interactions : GpgExpectConfig = GpgExpectConfig.from_yaml {{ read_file("#{__DIR__}/../resources/config_gpg_expect.yml") }}
    property gpg_config : GpgHomeConfig = GpgHomeConfig.from_yaml {{ read_file("#{__DIR__}/../resources/config_gnupg_home.yml") }}
    property key_config : KeyConfig = KeyConfig.from_yaml {{ read_file("#{__DIR__}/../resources/config_key.yml") }}
    property env_vars : Hash(String, String) = ENV.to_h
    property gpg_agent : GpgAgent
    property working_dir : Tempdir = Tempdir.new
    property outdir : String
    property report : Report = Report.new
    property pb : ProgressBar? = nil
    property gpg : String? = Process.find_executable "gpg"
    property gpgconf : String? = Process.find_executable "gpgconf"
    property ssh_add : String? = Process.find_executable "ssh-add"
    property ykman : String? = Process.find_executable "ykman"
    property bip39key : String? = Process.find_executable "bip39key"
    property systemctl : String? = Process.find_executable "systemctl"
    property timestamp : String?
    property expiry : String?

    def initialize(**args)
      super(**args)
      @gnupghome = @working_dir / "gnupghome"
      @env_vars["GNUPGHOME"] = "#{@gnupghome}"
      @gpg_agent = GpgAgent.new(@env_vars)
      @outdir = uninitialized String
      @gpg_key = uninitialized GpgKey
    end

    def setup : Nil
      @name = "dump"
      @description = "Dumps gpg subkeys to a hardware token"

      add_argument "filename", description: "Secret key filename - will generate a new key if not provided", required: false
      add_option 'i', "interactions", description: "GnuPG interactions file in YAML format", type: :single
      add_option 'c', "config", description: "Key configuration in YAML format", type: :single
      add_option 'f', "force", description: "Don't confirm destructive operations", type: :none
      add_option 'o', "outdir", description: "Public keys and revocation certificate location", type: :single, default: File.expand_path("~/Documents/#{SHARD["name"]}", home: true)
      add_option 'j', "json", description: "JSON output", type: :none
      add_option 't', "timestamp", description: "Key creation - parsed as UTC", type: :single
      add_option 'e', "expiry", description: "Key expiry - parsed as UTC", type: :single
      add_option 'h', "help", description: "Show usage"
    end

    def run(arguments : Cling::Arguments, options : Cling::Options) : Nil
      unless options.has?("help")
        @interactions = options.get?("interactions")
        @config = options.get?("config")
        @key_filename = arguments.get?("filename").to_s
        @outdir = options.get("outdir").to_s

        unless arguments.has?("filename")
          if timestamp = options.get?("timestamp")
            @timestamp = timestamp.to_s
          end
          if expiry = options.get?("expiry")
            @expiry = expiry.to_s
          end
        end

        Dir.mkdir_p(@outdir) unless File.exists?(@outdir)

        gpg_interactions if @interactions
        custom_key_config if @config

        gpg_config
        binary_check

        if Log.level.to_i >= 2 && !options.has?("json")
          @pb = ProgressBar.new(ticks: 10,
            charset: :bar,
            show_percentage: true)
          @pb.try &.init
        end

        if options.has?("force")
          card_reset
        else
          Helper.ask("Reset the card?", default: false) ? card_reset : exit_program(1)
        end

        @gpg_agent.toggle
        gpg_key_import_or_generate
        gpg_key_revcert
        gpg_key_public_export
        overrides
        card_set_keyattrs
        card_set_owner
        gpg_key_keytocard
        gpg_key_secret_delete
        ssh_key_public_create
        @gpg_agent.toggle

        if options.has?("json")
          puts @report.to_json
        else
          @report.show
        end
      end

      true
    end

    private def gpg_key_exists?
      if fname = @key_filename
        File.exists?(fname) &&
          File::Info.readable?(fname)
      else
        false
      end
    end

    private def gpg_key_import_or_generate
      if gpg_key_exists?
        gpg_key_import
      else
        key = Bip39key.new(self)
        @key_filename = key.key_filename
        # exit_program(1)
        gpg_key_import
      end
    end

    def pb_tick(msg : String | Nil = nil)
      @pb.try &.message("#{"✓".colorize(:green)} #{msg}...") if msg
      @pb.try &.tick
    end

    private def gpg_key_secret_delete
      Log.debug { "💡 gpg_key_secret_delete start" }
      binary_check_and_run(@gpg, "gpg", ["--batch",
                                         "--yes",
                                         "--delete-secret-keys",
                                         "#{@gpg_key.fingerprint}"], @env_vars) do |_|
        Log.debug { "#{"✓".colorize(:green)} gpg_key_secret_delete" }
        pb_tick("Deleted pgp secret key")
      end
    end

    private def gpg_key_public_export
      fname = "#{@outdir}/#{@gpg_key.fingerprint}_pgp_public_key.asc"
      File.delete(fname) if File.exists?(fname)

      Log.debug { "💡 gpg_key_public_export start" }

      binary_check_and_run(@gpg, "gpg", ["--output",
                                         fname,
                                         "--export",
                                         "-a",
                                         "#{@gpg_key.fingerprint}"], @env_vars) do |output|
        Log.trace { "#{output.inspect}" }
        Log.debug { "#{"✓".colorize(:green)} #{fname}" }
        @report.gpg_public_key = fname
        pb_tick("Exported pgp public key")
      end
    end

    private def ssh_key_public_create
      fname = "#{@outdir}/#{@gpg_key.fingerprint}_ssh_public_key.asc"
      File.delete(fname) if File.exists?(fname)

      binary_check_and_run(@gpgconf, "gpgconf", ["--list-dirs", "agent-ssh-socket"], @env_vars) do |output|
        @env_vars["SSH_AUTH_SOCK"] = output.strip
        Log.trace { "SSH_AUTH_SOCK=#{@env_vars["SSH_AUTH_SOCK"]}" }
      end

      File.write((@gnupghome / "sshcontrol"), "#{@gpg_key.keygrip}\n")

      Log.debug { "💡 ssh_key_public_create start" }
      binary_check_and_run(@ssh_add, "ssh-add", ["-L"], @env_vars) do |output|
        File.write(fname, "#{output.strip}\n")
        Log.trace { "#{output.inspect}" }
        Log.debug { "#{"✓".colorize(:green)} #{fname}" }
        @report.ssh_public_key = fname
        pb_tick("Created ssh public key")
      end
    end

    private def gpg_key_revcert
      if @gpg
        fname = "#{@outdir}/#{@gpg_key.fingerprint}_pgp_revocation_cert.asc"
        File.delete(fname) if File.exists?(fname)

        @gpg_interactions.key_revcert.args.concat ["--output",
                                                   fname,
                                                   "--generate-revocation",
                                                   "#{@gpg_key.fingerprint}"]

        Log.trace { "@gpg_interactions.key_revcert.args: #{@gpg_interactions.key_revcert.args.inspect}" }
        Log.trace { "@gpg_interactions.key_revcert.interactions: #{@gpg_interactions.key_revcert.interactions.inspect}" }
        Log.debug { "💡 key_revcert start" }

        res = Expect.interactive_process @gpg.to_s, @gpg_interactions.key_revcert, @env_vars
        if res[:status].success? || res[:status].exit_code != 1
          Log.debug { "#{"✓".colorize(:green)} #{fname}" }
          @report.gpg_revcert = fname
          pb_tick("Created revocation certificate")
        else
          Log.error { "key_revcert failure" }
          exit_program(1)
        end
      end
    end

    private def gpg_key_import
      fname_key = File.expand_path(@key_filename.to_s, home: true)
      fname_trust = @gnupghome / "trust.txt"

      binary_check_and_run(@gpg, "gpg", ["--import-options",
                                         "show-only",
                                         "--with-colons",
                                         "--import",
                                         "--with-fingerprint",
                                         fname_key], @env_vars) do |output|
        @gpg_key = GpgKey.new(output)
        subkeys = @gpg_key.subkeys.map { |subkey| "[#{subkey.capabilities}]#{subkey.key_id}" }
        Log.debug { "#{"✓".colorize(:green)} #{@gpg_key.primary_key.type}: (#{@gpg_key.fingerprint}) [#{@gpg_key.primary_key.capabilities}] found." }
        Log.trace { "#{subkeys.join(", ")}" }
      end

      File.write(fname_trust, "#{@gpg_key.fingerprint}:6:\n")

      binary_check_and_run(@gpg, "gpg", ["--import", fname_key.to_s], @env_vars) do |_|
        Log.debug { "#{"✓".colorize(:green)} #{@gpg_key.fingerprint} imported." }
      end

      binary_check_and_run(@gpg, "gpg", ["--import-ownertrust", fname_trust.to_s], @env_vars) do |_|
        Log.debug { "#{"✓".colorize(:green)} Owner trust imported" }
      end

      Log.debug { "GNUPGHOME=#{@gnupghome}" }

      @report.gpg_key = @gpg_key
      pb_tick("Imported secret key")
    end

    private def gpg_config
      File.chmod(@gnupghome, 0o700)
      File.write((@gnupghome / "gpg-agent.conf"), @gpg_config.gpg_agent)
      File.write((@gnupghome / "gpg.conf"), @gpg_config.gpg)
      File.write((@gnupghome / "scdaemon.conf"), @gpg_config.scdaemon)
      Log.trace { "#{Dir.glob(@gnupghome / "*").inspect}" }
    end

    private def overrides
      if user_config = @key_config.user
        owner_interactions = @gpg_interactions.card_set_owner.interactions
        owner_interactions.each do |interaction|
          case interaction["pattern"]?
          when "keygen.smartcard.surname"
            if last_name = user_config.last_name
              interaction["response"] = last_name
              Log.trace { "Overrode 'keygen.smartcard.surname' with user's last name." }
            end
          when "keygen.smartcard.givenname"
            if first_name = user_config.first_name
              interaction["response"] = first_name
              Log.trace { "Overrode 'keygen.smartcard.givenname' with user's first name." }
            end
          when "cardedit.change_login"
            # ISSUE: https://github.com/drduh/YubiKey-Guide/issues/461
            if email = @gpg_key.user_ids.first.user_id_string.match(/<([^>]+)>/i)
              interaction["response"] = email.to_s
              Log.trace { "Overrode 'cardedit.change_login' with @gpg_key.user_ids.first.user_id_string" }
            end
          else
          end
        end
      end
      Log.trace { "#{@gpg_interactions.card_set_owner.interactions.inspect}" }
    end

    private def gpg_interactions
      if interactions = @interactions
        file = File.expand_path(interactions.as_s)
        if File.exists?(file) && !File.empty?(file)
          Log.debug { "#{file}: custom interactions file found" }
          @gpg_interactions = GpgExpectConfig.from_yaml(File.read(file))
        else
          Log.warn { "#{file}: custom interactions file not found or empty" }
        end
      end
    end

    private def custom_key_config
      if config = @config
        file = File.expand_path(config.as_s)
        if File.exists?(file) && !File.empty?(file)
          Log.debug { "#{file}: custom key config file found" }
          @key_config = KeyConfig.from_yaml(File.read(file))
          Log.trace { "#{@key_config.inspect}" }
        else
          Log.warn { "#{file}: custom key config file not found or empty" }
        end
      end
    end

    private def card_reset
      if @gpg
        Log.trace { "@gpg_interactions.card_reset.args: #{@gpg_interactions.card_reset.args.inspect}" }
        Log.trace { "@gpg_interactions.card_reset.interactions: #{@gpg_interactions.card_reset.interactions.inspect}" }
        Log.debug { "💡 card_reset start" }

        binary_check_and_run(@ykman, "ykman", ["openpgp", "reset", "--force"], @env_vars) do |_|
          Log.debug { "#{"✓".colorize(:green)} card_reset success" }
          pb_tick("Reset card")
        end
      end
    end

    private def card_set_keyattrs
      if @gpg
        Log.trace { "@gpg_interactions.card_set_keyattrs.args: #{@gpg_interactions.card_set_keyattrs.args.inspect}" }
        Log.trace { "@gpg_interactions.card_set_keyattrs.interactions: #{@gpg_interactions.card_set_keyattrs.interactions.inspect}" }
        Log.debug { "💡 card_set_keyattrs start" }
        res = Expect.interactive_process @gpg.to_s, @gpg_interactions.card_set_keyattrs, @env_vars
        if res[:status].success? || res[:status].exit_code != 1
          Log.debug { "#{"✓".colorize(:green)} card_set_keyattrs success" }
          pb_tick("Set key attributes")
        else
          Log.error { "card_set_keyattrs failure" }
        end
      end
    end

    private def card_set_owner
      if @gpg
        Log.trace { "@gpg_interactions.card_set_owner.args: #{@gpg_interactions.card_set_owner.args.inspect}" }
        Log.trace { "@gpg_interactions.card_set_owner.interactions: #{@gpg_interactions.card_set_owner.interactions.inspect}" }
        Log.debug { "💡 card_set_owner start" }
        res = Expect.interactive_process @gpg.to_s, @gpg_interactions.card_set_owner, @env_vars
        if res[:status].success? || res[:status].exit_code != 1
          Log.debug { "#{"✓".colorize(:green)} card_set_owner success" }
          pb_tick("Set card owner information")
        else
          Log.error { "card_set_owner failure" }
        end
      end
    end

    private def gpg_key_keytocard
      if @gpg
        @gpg_interactions.key_keytocard.args << "#{@gpg_key.fingerprint}"
        Log.trace { "@gpg_interactions.key_keytocard.args: #{@gpg_interactions.key_keytocard.args.inspect}" }
        Log.trace { "@gpg_interactions.key_keytocard.interactions: #{@gpg_interactions.key_keytocard.interactions.inspect}" }
        Log.debug { "💡 key_keytocard start" }
        res = Expect.interactive_process @gpg.to_s, @gpg_interactions.key_keytocard, @env_vars
        if res[:status].success? || res[:status].exit_code != 1
          Log.debug { "#{"✓".colorize(:green)} key_keytocard success" }
          pb_tick("Moved subkeys to card")
        else
          Log.error { "key_keytocard failure" }
        end
      end
    end

    private def all_partials_matched(partials_to_find : Array(String),
                                     target_strings : Array(String)) : Bool
      return false if partials_to_find.empty?
      partials_to_find.all? do |partial|
        target_strings.any? do |target_string|
          target_string =~ /#{partial}/i
        end
      end
    end

    private def get_pkcheck_process_string : String
      pid = Process.pid
      uid = Dkeygen.geteuid # Effective User ID of the current process
      stat_file_path = "/proc/#{pid}/stat"

      unless File.exists?(stat_file_path) && File::Info.readable?(stat_file_path)
        Log.error { "Cannot read /proc/#{pid}/stat. This method is Linux-specific and requires /procfs." }
        exit_program(1)
      end

      stat_content = File.read(stat_file_path)
      stat_fields = stat_content.split(' ')
      if stat_fields.size < 22
        Log.error { "Unexpected format for /proc/#{pid}/stat. Expected at least 22 fields, got #{stat_fields.size}." }
        exit_program(1)
      end

      start_time = stat_fields[21]

      "#{pid},#{start_time},#{uid}"
    end

    private def binary_check
      process_arg = get_pkcheck_process_string
      # Check pkcheck
      binary_check_and_run(Process.find_executable("pkcheck"), "pkcheck", ["--version"]) do |output|
        Log.debug { "#{"✓".colorize(:green)} #{output.strip}" }
      end

      # Ensure org.debian.pcsc-lite.access_card permission
      binary_check_and_run(Process.find_executable("pkcheck"),
        "pkcheck", ["--action-id",
                    "org.debian.pcsc-lite.access_card",
                    "--process", process_arg]) do |output|
        Log.debug { "#{"✓".colorize(:green)} org.debian.pcsc-lite.access_card" }
      end

      # Ensure org.debian.pcsc-lite.access_pcsc permission
      binary_check_and_run(Process.find_executable("pkcheck"),
        "pkcheck", ["--action-id",
                    "org.debian.pcsc-lite.access_pcsc",
                    "--process", process_arg]) do |output|
        Log.debug { "#{"✓".colorize(:green)} org.debian.pcsc-lite.access_pcsc" }
      end

      # Check bip39key
      binary_check_and_run(@bip39key, "bip39key", ["--help"]) do |output|
        available_args = output.split("--").map(&.split("\n").first.split(" ").first)
        required_args = ["authorization-for-sign-key", "generate-sign-subkey", "generate-auth-key"]
        if !all_partials_matched(required_args, available_args)
          Log.error { "bip39key does not support SAE subkeys! - get the supported version: https://github.com/voobscout/bip39key" }
          exit_program(1)
        else
          Log.debug { "#{"✓".colorize(:green)} bip39key SAE subkeys support" }
        end
        Log.trace { "#{available_args.inspect}" }
      end

      # Check ykman
      binary_check_and_run(@ykman, "ykman", ["--version"], @env_vars) do |output|
        ykman_version = output.split(" ").last.strip
        Log.debug { "#{"✓".colorize(:green)} ykman v#{ykman_version}" }
      end

      # Check gpg
      binary_check_and_run(@gpg, "gpg", ["--version"], @env_vars) do |output|
        gpg_version = output.lines.first.split(" ").last.strip
        Log.debug { "#{"✓".colorize(:green)} gpg v#{gpg_version}" }
      end

      # Check systemctl
      binary_check_and_run(@systemctl, "systemctl", ["--version"], @env_vars) do |output|
        systemctl_version = output.lines.first.split(" ")[1]
        Log.debug { "#{"✓".colorize(:green)} systemctl v#{systemctl_version}" }
      end
    end
  end
end
