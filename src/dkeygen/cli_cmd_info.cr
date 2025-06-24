module Dkeygen
  class Info < Cling::Command
    def setup : Nil
      @name = "info"
      @description = "Show secret key info"

      add_argument "filename", description: "Secret key filename", required: true
    end

    def run(arguments : Cling::Arguments, options : Cling::Options) : Nil
    end
  end
end
