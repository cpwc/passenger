# encoding: binary
#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2010-2015 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  See LICENSE file for license information.

require 'socket'
PhusionPassenger.require_passenger_lib 'message_channel'
PhusionPassenger.require_passenger_lib 'utils'

module PhusionPassenger

  # A convenience class for communicating with MessageServer servers,
  # for example the ApplicationPool server.
  class MessageClient
    include Utils

    # Connect to the given server. By default it connects to the current
    # generation's core.
    def initialize(username, password, address)
      @socket = connect_to_server(address)
      begin
        @channel = MessageChannel.new(@socket)

        result = @channel.read
        if result.nil?
          raise EOFError
        elsif result.size != 2 || result[0] != "version"
          raise IOError, "The message server didn't sent a valid version identifier"
        elsif result[1] != "1"
          raise IOError, "Unsupported message server protocol version #{result[1]}"
        end

        @channel.write_scalar(username)
        @channel.write_scalar(password)

        result = @channel.read
        if result.nil?
          raise EOFError
        elsif result[0] != "ok"
          raise SecurityError, result[0]
        end
      rescue Exception
        @socket.close
        raise
      end
    end

    def close
      @socket.close if @socket
      @channel = @socket = nil
    end

    def connected?
      return !!@channel
    end

    ### Passenger core process methods ###

    def pool_detach_process(pid)
      write("detach_process", pid)
      check_security_response
      result = read
      if result.nil?
        raise EOFError
      else
        return result.first == "true"
      end
    end

    def pool_detach_process_by_key(detach_key)
      write("detach_process_by_key", detach_key)
      check_security_response
      result = read
      if result.nil?
        raise EOFError
      else
        return result.first == "true"
      end
    end

    def pool_status(options = {})
      write("inspect", *options.to_a.flatten)
      check_security_response
      return read_scalar
    rescue
      auto_disconnect
      raise
    end

    def pool_xml
      write("toXml", true)
      check_security_response
      return read_scalar
    end

    def restart_app_group(app_group_name, options = {})
      write("restart_app_group", app_group_name, *options.to_a.flatten)
      check_security_response
      result = read
      if result.nil?
        raise EOFError
      else
        return result.first == "true"
      end
    end

    def core_requests
      write("requests")
      check_security_response
      return read_scalar
    end

    ### Passenger core BacktracesServer methods ###

    def core_backtraces
      write("backtraces")
      check_security_response
      return read_scalar
    end

    ### Passenger UstRouter AdminServer methods ###

    def ust_router_status
      write("status")
      check_security_response
      return read_scalar
    end

    ### Low level I/O methods ###

    def read
      return @channel.read
    rescue
      auto_disconnect
      raise
    end

    def write(*args)
      @channel.write(*args)
    rescue
      auto_disconnect
      raise
    end

    def write_scalar(*args)
      @channel.write_scalar(*args)
    rescue
      auto_disconnect
      raise
    end

    def read_scalar
      return @channel.read_scalar
    rescue
      auto_disconnect
      raise
    end

    def recv_io(klass = IO, negotiate = true)
      return @channel.recv_io(klass, negotiate)
    rescue
      auto_disconnect
      raise
    end

    def check_security_response
      begin
        result = @channel.read
      rescue
        auto_disconnect
        raise
      end
      if result.nil?
        raise EOFError
      elsif result[0] != "Passed security"
        raise SecurityError, result[0]
      end
    end

  private
    def auto_disconnect
      if @channel
        @socket.close rescue nil
        @socket = @channel = nil
      end
    end
  end

end # module PhusionPassenger
