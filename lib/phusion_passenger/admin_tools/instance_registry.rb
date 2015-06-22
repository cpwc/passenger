# encoding: utf-8
#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2014-2015 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  See LICENSE file for license information.

require 'fileutils'
PhusionPassenger.require_passenger_lib 'admin_tools/instance'

module PhusionPassenger
  module AdminTools

    class InstanceRegistry
      def initialize(paths = nil)
        @paths = [paths || default_paths].flatten
      end

      def list(options = {})
        options = {
          :clean_stale_or_corrupted => true
        }.merge(options)

        instances = []

        @paths.each do |path|
          Dir["#{path}/passenger.*"].each do |dir|
            instance = Instance.new(dir)
            case instance.state
            when :good
              if instance.locked?
                instances << instance
              elsif options[:clean_stale_or_corrupted]
                cleanup(dir)
              end
            when :structure_version_unsupported
              next
            when :corrupted
              if !instance.locked? && options[:clean_stale_or_corrupted]
                cleanup(dir)
              end
            when :not_finalized
              if instance.stale? && options[:clean_stale_or_corrupted]
                cleanup(dir)
              end
            end
          end
        end

        instances
      end

      def find_by_name(name, options = {})
        return list(options).find { |instance| instance.name == name }
      end

      def find_by_name_prefix(name, options = {})
        prefix = /^#{Regexp.escape name}/
        results = list(options).find_all { |instance| instance.name =~ prefix }
        if results.size <= 1
          return results.first
        else
          return :ambiguous
        end
      end

    private
      def default_paths
        if result = string_env("PASSENGER_INSTANCE_REGISTRY_DIR")
          return [result]
        end

        # On OSX, TMPDIR is set to a different value per-user. But Apache
        # is launched through Launchctl and runs without TMPDIR (and thus
        # uses the default /tmp).
        #
        # The RPM packages configure Apache and Nginx to use /var/run/passenger-instreg
        # as the instance registry dir. See https://github.com/phusion/passenger/issues/1475
        [string_env("TMPDIR"), "/tmp", "/var/run/passenger-instreg"].compact
      end

      def string_env(name)
        if (result = ENV[name]) && !result.empty?
          result
        else
          nil
        end
      end

      def cleanup(path)
        puts "*** Cleaning stale instance directory #{path}"
        begin
          FileUtils.chmod_R(0700, path) rescue nil
          FileUtils.remove_entry_secure(path)
        rescue SystemCallError => e
          puts "    Warning: #{e}"
        end
      end
    end

  end # module AdminTools
end # module PhusionPassenger
