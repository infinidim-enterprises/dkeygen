module Dkeygen
  class PrimaryKeyInfo
    include YAML::Serializable
    include JSON::Serializable

    getter type : String
    getter validity : Char
    getter key_length : Int32
    getter pub_algo : Int32
    getter key_id : String
    getter creation_date : Time
    getter expiration_date : Time?
    getter ownertrust : Char?
    getter capabilities : String
    getter curve_name : String?

    property keygrip : String?
    property fingerprint : String

    def initialize(@type : String,
                   @validity : Char,
                   @key_length : Int32,
                   @pub_algo : Int32,
                   @key_id : String,
                   @creation_date : Time,
                   @expiration_date : Time?,
                   @ownertrust : Char?,
                   @capabilities : String,
                   @curve_name : String? = nil)
      @keygrip = nil
      @fingerprint = ""
    end
  end

  class SubkeyInfo
    include YAML::Serializable
    include JSON::Serializable

    getter type : String
    getter validity : Char
    getter key_length : Int32
    getter pub_algo : Int32
    getter key_id : String
    getter creation_date : Time
    getter expiration_date : Time?
    getter capabilities : String
    getter curve_name : String?

    property keygrip : String?
    property fingerprint : String

    def initialize(@type : String,
                   @validity : Char,
                   @key_length : Int32,
                   @pub_algo : Int32,
                   @key_id : String,
                   @creation_date : Time,
                   @expiration_date : Time?,
                   @capabilities : String,
                   @curve_name : String? = nil)
      @keygrip = nil
      @fingerprint = ""
    end
  end

  struct UserIdInfo
    include YAML::Serializable
    include JSON::Serializable

    getter type : String
    getter validity : Char
    getter user_id_string : String
    getter creation_date : Time
    getter expiration_date : Time?
    getter preferences : String?

    def initialize(@type : String,
                   @validity : Char,
                   @user_id_string : String,
                   @creation_date : Time,
                   @expiration_date : Time?,
                   @preferences : String? = nil)
    end
  end

  class GpgKey
    include YAML::Serializable
    include JSON::Serializable

    getter primary_key : PrimaryKeyInfo
    getter user_ids : Array(UserIdInfo)
    getter subkeys : Array(SubkeyInfo)

    def fingerprint : String
      primary_key.fingerprint
    end

    def key_id : String
      primary_key.key_id
    end

    def keygrip : String?
      primary_key.keygrip
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def initialize(gpg_output : String)
      @user_ids = [] of UserIdInfo
      @subkeys = [] of SubkeyInfo
      @primary_key = uninitialized PrimaryKeyInfo

      current_key_context : PrimaryKeyInfo? = nil
      current_subkey_context : SubkeyInfo? = nil

      gpg_output.each_line do |line|
        fields = line.strip.split(':')
        next if fields.empty?

        record_type = fields[0].not_nil!

        case record_type
        when "pub", "sec"
          validity = fields[1]?.try(&.chars.first) || '-'
          key_length = fields[2]?.try(&.to_i) || 0
          pub_algo = fields[3]?.try(&.to_i) || 0
          key_id = fields[4]? || ""

          creation_date = parse_timestamp(fields[5]?).as(Time)
          expiration_date = parse_timestamp(fields[6]?)
          ownertrust = fields[8]?.try(&.chars.first)
          capabilities = fields[11]? || ""
          curve_name = fields[16]?.presence

          current_key_context = PrimaryKeyInfo.new(type: record_type,
            validity: validity,
            key_length: key_length,
            pub_algo: pub_algo,
            key_id: key_id,
            creation_date: creation_date,
            expiration_date: expiration_date,
            ownertrust: ownertrust,
            capabilities: capabilities,
            curve_name: curve_name)

          @primary_key = current_key_context
          current_subkey_context = nil
        when "sub", "ssb"
          validity = fields[1]?.try(&.chars.first) || '-'
          key_length = fields[2]?.try(&.to_i) || 0
          pub_algo = fields[3]?.try(&.to_i) || 0
          key_id = fields[4]? || ""
          creation_date = parse_timestamp(fields[5]?).as(Time)
          expiration_date = parse_timestamp(fields[6]?)
          capabilities = fields[11]? || ""
          curve_name = fields[16]?.presence

          current_subkey_context = SubkeyInfo.new(type: record_type,
            validity: validity,
            key_length: key_length,
            pub_algo: pub_algo,
            key_id: key_id,
            creation_date: creation_date,
            expiration_date: expiration_date,
            capabilities: capabilities,
            curve_name: curve_name)

          @subkeys << current_subkey_context
          current_key_context = nil
        when "uid", "uat"
          validity = fields[1]?.try(&.chars.first) || '-'
          user_id_string = unquote_c_string(fields[9]? || "")
          creation_date = parse_timestamp(fields[5]?).as(Time)
          expiration_date = parse_timestamp(fields[6]?)
          preferences = fields[12]?.presence

          @user_ids << UserIdInfo.new(type: record_type,
            validity: validity,
            user_id_string: user_id_string,
            creation_date: creation_date,
            expiration_date: expiration_date,
            preferences: preferences)
        when "fpr"
          fingerprint = fields[9]? || ""
          if current_key_context
            current_key_context.fingerprint = fingerprint
          elsif current_subkey_context
            current_subkey_context.fingerprint = fingerprint
          end
        when "grp"
          keygrip = fields[9]?.presence
          if current_key_context
            current_key_context.keygrip = keygrip
          elsif current_subkey_context
            current_subkey_context.keygrip = keygrip
          end
        else
        end
      end

      unless @primary_key.is_a?(PrimaryKeyInfo)
        raise ArgumentError.new("Invalid GPG key output: No primary key (pub/sec) record found.")
      end
    end

    private def parse_timestamp(timestamp_str : String?) : Time?
      return nil if timestamp_str.nil? || timestamp_str.empty? || timestamp_str == "0"

      if timestamp_str.includes?('T')
        begin
          Time.parse(timestamp_str, "%Y%m%dT%H%M%S", Time::Location::UTC)
        rescue ArgumentError
          nil
        end
      else
        begin
          Time.unix(timestamp_str.to_i)
        rescue ArgumentError
          nil
        end
      end
    end

    private def unquote_c_string(quoted_str : String) : String
      unquoted = quoted_str.gsub(/\\\\/, "\\")
      unquoted = unquoted.gsub(/\\n/, "\n")
      unquoted = unquoted.gsub(/\\t/, "\t")
      unquoted = unquoted.gsub(/\\r/, "\r")
      unquoted = unquoted.gsub(/\\"/, "\"")
      unquoted = unquoted.gsub(/\\:/, ":")

      unquoted.gsub(/\\x([0-9a-fA-F]{2})/) do |match|
        byte_val = match[2..-1].to_i(16)
        byte_val.chr
      end
    end
  end
end
