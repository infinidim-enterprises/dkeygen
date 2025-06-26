require "tallboy"

module Dkeygen
  class Report
    property gpg_key : GpgKey
    property gpg_public_key : String
    property ssh_public_key : String
    property gpg_revcert : String
    property mnemonic : Array(String)?

    def initialize
      @gpg_key = uninitialized GpgKey
      @gpg_public_key = uninitialized String
      @ssh_public_key = uninitialized String
      @gpg_revcert = uninitialized String
    end

    def show
      key_info = "#{gpg_key.user_ids.first.user_id_string}\n" +
                 "#{gpg_key.fingerprint.colorize(:red)}"

      commands = "gpg --import #{gpg_public_key}\n" +
                 "echo '#{gpg_key.fingerprint}:6:' | gpg --import-ownertrust\n" +
                 "echo '#{@gpg_key.keygrip}' >> \"$GNUPGHOME/sshcontrol\"\n" +
                 "cat #{@ssh_public_key} >> \"$HOME/.ssh/authorized_keys\"\n"

      table = Tallboy.table do
        columns do
          add "path"
          add "type"
        end

        header key_info, align: :left
        header

        rows [["#{gpg_public_key}", "pgp public key"],
              ["#{ssh_public_key}", "ssh public key"],
              ["#{gpg_revcert}", "gpg revocation cert"]]
      end

      puts table
      puts commands
      puts "Mnemonic:\n#{self.mnemonic.try &.join(" ")}" if self.mnemonic
    end
  end
end
