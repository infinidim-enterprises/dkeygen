module Dkeygen
  class GpgCommandConfig
    include YAML::Serializable

    property args : Array(String)
    property interactions : Array(Hash(String, String))
    property meta : Hash(String, String)? = nil
  end

  class GpgExpectConfig
    include YAML::Serializable

    property card_reset : GpgCommandConfig
    property card_set_keyattrs : GpgCommandConfig
    property card_set_owner : GpgCommandConfig
    property key_keytocard : GpgCommandConfig
    property key_revcert : GpgCommandConfig
  end

  class Bip39KeyConfig
    include YAML::Serializable

    property args : Array(String)
  end

  class UserConfig
    include YAML::Serializable

    property first_name : String | Nil
    property last_name : String | Nil
    property email : String | Nil
    property mnemonic : String | Nil
  end

  class KeyConfig
    include YAML::Serializable

    property bip39key : Bip39KeyConfig
    property user : UserConfig
  end

  class GpgHomeConfig
    include YAML::Serializable

    property gpg_agent : String | Nil
    property gpg : String | Nil
    property scdaemon : String | Nil
  end
end
