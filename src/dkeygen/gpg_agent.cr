require "json"
require "ini"
require "socket"

module Dkeygen
  class GpgAgent
    Log = ::Log.for(self)

    property gpg_agent_units : Array(String) = [] of String
    property env_vars : Hash(String, String)
    property? active : Bool = false

    def initialize(@env_vars : Hash(String, String))
      find_units
    end

    def toggle
      if self.active?
        stop
        self.active = false
      else
        start
        self.active = true
      end
    end

    def refresh_state
      stop_gpg_agent
      start_gpg_agent
    end

    # Start custom gpg-agent
    private def start
      stop_systemd_units
      start_gpg_agent
    end

    # stop custom gpg-agent
    private def stop
      stop_gpg_agent
      start_systemd_units
    end

    private def start_gpg_agent
      # NOTE: This will start the gpg-agent if it isn't running
      args = ["--list-keys", "--with-colons"]
      res = Expect.none_interactive_process Process.find_executable("gpg").to_s, args, self.env_vars

      if res[:status].success?
        Log.debug {"#{"✓".colorize(:green)} gpg-agent start"}
      else
        Log.error { "gpg #{args.join(" ")} - Failed to run #{res[:output].inspect}" }
      end
    end

    private def start_gpg_agent_old
      # NOTE: This will start the gpg-agent if it isn't running
      args = ["--card-status", "--with-colons"]
      res = Expect.none_interactive_process Process.find_executable("gpg").to_s, args, self.env_vars

      if res[:status].success?
        info = res[:output].lines.map(&.split(":").reject { |i| i == "" })
        vendor = info[2][2]
        serial = info[3][1]
        Log.debug {"#{"✓".colorize(:green)} #{vendor} (S/n): #{serial}"}
      else
        Log.error { "gpg #{args.join(" ")} - Failed to run #{res[:output].inspect}" }
      end
    end

    private def stop_gpg_agent
      args = ["--kill", "all"]
      res = Expect.none_interactive_process Process.find_executable("gpgconf").to_s, args, self.env_vars

      if res[:status].success?
        Log.debug {"#{"✓".colorize(:green)} gpg-agent stop"}
      else
        Log.error { "gpgconf #{args.join(" ")} - Failed to run" }
      end
    end

    private def stop_systemd_units
      args = ["--user", "stop"] + self.gpg_agent_units
      res = Expect.none_interactive_process Process.find_executable("systemctl").to_s, args

      if res[:status].success?
        Log.debug {"#{"✓".colorize(:green)} systemctl #{args.join(" ")}"}
      else
        Log.error { "systemctl #{args.join(" ")} - Failed to run" }
      end
    end

    private def get_gpg_agent_pid(socket_path : String) : String?
      return unless File.exists?(socket_path) && File.info(socket_path).type.socket?

      begin
        UNIXSocket.open(socket_path) do |sock|
          greeting = sock.gets
          return unless greeting && greeting.starts_with?("OK Pleased to meet you")

          sock.puts "GETINFO pid"
          pid_line = sock.gets
          ok_line  = sock.gets

          if pid_line && pid_line.starts_with?("D ") && ok_line == "OK"
            return pid_line.split(" ", 2)[1]?
          end
        end
      rescue IO::Error | Socket::ConnectError
      end
    end

    private def start_service_unit? : Bool
      final_res = false
      service_unit = self.gpg_agent_units.select { |e| e =~ /service/i }

      unless service_unit.empty?
        args = ["--user", "cat"] + service_unit
        res = Expect.none_interactive_process Process.find_executable("systemctl").to_s, args

        if res[:status].success?
          final_res = true unless INI.parse(res[:output])["Unit"]["RefuseManualStart"]?
          Log.trace {"#{service_unit.first} should not be started!"}
        else
          Log.error { "systemctl #{args.join(" ")} - Failed to run" }
        end
      end
      final_res
    end

    private def start_systemd_units
      units = if !start_service_unit?
                self.gpg_agent_units.reject { |e| e =~ /service/i}
              else
                self.gpg_agent_units
              end

      args = ["--user", "start"] + units
      res = Expect.none_interactive_process Process.find_executable("systemctl").to_s, args

      if res[:status].success?
        Log.debug {"#{"✓".colorize(:green)} systemctl #{args.join(" ")}"}
      else
        Log.error { "systemctl #{args.join(" ")} - Failed to run" }
      end
    end

    private def find_units
      args = ["--user", "list-unit-files", "--output=json"]
      res = Expect.none_interactive_process Process.find_executable("systemctl").to_s, args

      if res[:status].success?
        self.gpg_agent_units = JSON.parse(res[:output])
                               .as_a.select { |e| e["unit_file"].as_s =~ /gpg/i }
                               .map(&.["unit_file"].as_s).reverse!
      else
        Log.error { "systemctl #{args.join(" ")} - Failed to run" }
      end
    end
  end
end
