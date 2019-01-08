module Beaker
  module DSL
    module InstallUtils
      #
      # This module contains methods useful for both foss and pe installs
      #
      module PuppetUtils

        #Given a type return an understood host type
        #@param [String] type The host type to be normalized
        #@return [String] The normalized type
        #
        #@example
        #  normalize_type('pe-aio')
        #    'pe'
        #@example
        #  normalize_type('git')
        #    'foss'
        #@example
        #  normalize_type('foss-internal')
        #    'foss'
        def normalize_type type
          case type
          when /(\A|-)foss(\Z|-)/
            'foss'
          when /(\A|-)pe(\Z|-)/
            'pe'
          when /(\A|-)aio(\Z|-)/
            'aio'
          else
            nil
          end
        end

        #Given a host construct a PATH that includes puppetbindir, facterbindir and hierabindir
        # @param [Host] host    A single host to construct pathing for
        def construct_puppet_path(host)
          path = (%w(puppetbindir facterbindir hierabindir privatebindir)).compact.reject(&:empty?)
          #get the PATH defaults
          path.map! { |val| host[val] }
          path = path.compact.reject(&:empty?)
          #run the paths through echo to see if they have any subcommands that need processing
          path.map! { |val| echo_on(host, val) }

          separator = host['pathseparator']
          if not host.is_powershell?
            separator = ':'
          end
          path.join(separator)
        end

        #Append puppetbindir, facterbindir and hierabindir to the PATH for each host
        # @param [Host, Array<Host>, String, Symbol] hosts    One or more hosts to act upon,
        #                            or a role (String or Symbol) that identifies one or more hosts.
        def add_puppet_paths_on(hosts)
          block_on hosts do | host |
            puppet_path = construct_puppet_path(host)
            host.add_env_var('PATH', puppet_path)
            host.add_env_var('PATH', 'PATH') # don't destroy the path!
          end
        end

        #Remove puppetbindir, facterbindir and hierabindir to the PATH for each host
        #
        # @param [Host, Array<Host>, String, Symbol] hosts    One or more hosts to act upon,
        #                            or a role (String or Symbol) that identifies one or more hosts.
        def remove_puppet_paths_on(hosts)
          block_on hosts do | host |
            puppet_path = construct_puppet_path(host)
            host.delete_env_var('PATH', puppet_path)
            host.add_env_var('PATH', 'PATH') # don't destroy the path!
          end
        end

        # Given an agent_version, return the puppet collection associated with that agent version
        #
        # @param [String] agent_version version string or 'latest'
        # @deprecated This method returns 'PC1' as the latest puppet collection;
        #     this is incorrect. Use {#puppet_collection_for_puppet_agent_version} or
        #     {#puppet_collection_for_puppet_version} instead.
        def get_puppet_collection(agent_version = 'latest')
          collection = "PC1"
          if agent_version != 'latest'
            if ! version_is_less( agent_version, "5.5.4") and version_is_less(agent_version, "5.99")
              collection = "puppet5"
            elsif ! version_is_less( agent_version, "5.99")
              collection = "puppet6"
            end
          end
          collection
        end

        # Determine the puppet collection that matches a given version of the puppet-agent
        # package (you can find this version in the `aio_agent_version` fact).
        #
        # @param agent_version [String] a semver version number of the puppet-agent package, or the string 'latest'
        # @returns [String|nil] the name of the corresponding puppet collection, if any
        def puppet_collection_for_puppet_agent_version(agent_version)
          return 'puppet' if agent_version.strip == 'latest'

          x, y, z = agent_version.to_s.split('.').map(&:to_i)
          return nil if x.nil? || y.nil? || z.nil?

          return 'pc1' if x == 1

          # A y version >= 99 indicates a pre-release version of the next x release
          x += 1 if y >= 99
          "puppet#{x}" if x > 4
        end

        # Determine the puppet collection that matches a given version of the puppet gem.
        #
        # @param version [String] a semver version number of the puppet gem, or the string 'latest'
        # @returns [String|nil] the name of the corresponding puppet collection, if any
        def puppet_collection_for_puppet_version(puppet_version)
          return 'puppet' if puppet_version.strip == 'latest'

          x, y, z = puppet_version.to_s.split('.').map(&:to_i)
          return nil if x.nil? || y.nil? || z.nil?

          return 'pc1' if x == 4

          # A y version >= 99 indicates a pre-release version of the next x release
          x += 1 if y >= 99
          "puppet#{x}" if x > 4
        end

        # Report the version of puppet-agent installed on `host`
        #
        # @param [Host] host The host to act upon
        # @returns [String|nil] The version of puppet-agent, or nil if puppet-agent is not installed
        def puppet_agent_version_on(host)
          result = on(host, 'facter aio_agent_version', accept_all_exit_codes: true)
          if result.exit_code.zero?
            return result.stdout.strip
          end
        end

        # Report the version of puppetserver installed on `host`
        #
        # @param [Host] host The host to act upon
        # @returns [String|nil] The version of puppetserver, or nil if puppetserver is not installed
        def puppetserver_version_on(host)
          result = on(host, 'puppetserver --version', accept_all_exit_codes: true)
          if result.exit_code.zero?
            matched = result.stdout.strip.scan(%r{\d+\.\d+\.\d+})
            return matched.last
          end
        end

        #Configure the provided hosts to be of the provided type (one of foss, aio, pe), if the host
        #is already associated with a type then remove the previous settings for that type
        # @param [Host, Array<Host>, String, Symbol] hosts    One or more hosts to act upon,
        #                            or a role (String or Symbol) that identifies one or more hosts.
        # @param [String] type One of 'aio', 'pe' or 'foss'
        def configure_defaults_on( hosts, type )
          block_on hosts do |host|

            # check to see if the host already has a type associated with it
            remove_defaults_on(host)

            add_method = "add_#{type}_defaults_on"
            if self.respond_to?(add_method, host)
              self.send(add_method, host)
            else
              raise "cannot add defaults of type #{type} for host #{host.name} (#{add_method} not present)"
            end
            # add pathing env
            add_puppet_paths_on(host)
          end
        end

        # Configure the provided hosts to be of their host[:type], it host[type] == nil do nothing
        def configure_type_defaults_on( hosts )
          block_on hosts do |host|
            has_defaults = false
            if host[:type]
              host_type = host[:type]
              # clean up the naming conventions here (some teams use foss-package, git-whatever, we need
              # to correctly handle that
              # don't worry about aio, that happens in the aio_version? check
              host_type = normalize_type(host_type)
              if host_type and host_type !~ /aio/
                add_method = "add_#{host_type}_defaults_on"
                if self.respond_to?(add_method, host)
                  self.send(add_method, host)
                else
                  raise "cannot add defaults of type #{host_type} for host #{host.name} (#{add_method} not present)"
                end
                has_defaults = true
              end
            end
            if aio_version?(host)
              add_aio_defaults_on(host)
              has_defaults = true
            end
            # add pathing env
            if has_defaults
              add_puppet_paths_on(host)
            end
          end
        end
        alias_method :configure_foss_defaults_on, :configure_type_defaults_on
        alias_method :configure_pe_defaults_on, :configure_type_defaults_on

        # Signs puppet certs for `hosts` on the master
        # @param [Host|Array<Host>] hosts Agent hosts to sign certs for
        # @raises when there is no master
        # @raises when puppetserver is not installed on the master already
        def sign_agent_cert_for(hosts)
          num_masters = hosts_with_role(hosts, :master).length
          raise "Unable to find a single master node (found #{num_masters})" unless num_masters == 1

          puppetserver_version = puppetserver_version_on(master)
          raise "Puppetserver must be installed on #{master} before agent certs can be signed" unless puppetserver_version

          # Puppet 6+ uses an intermediate CA (`puppetserver ca` instead of `puppet cert` etc.)
          use_intermediate_ca = !version_is_less(puppetserver_version, '5.99')

          # First, stop puppetserver, if necessary. A running master will
          # potentially ignore puppet.conf changes.
          logger.notify('Stop puppetserver')

          if master.use_service_scripts?
            on(master, puppet('resource', 'service', 'puppetserver', 'ensure=stopped'))
          end

          # Clear SSL on the hosts so that we can newly associate the agents
          logger.notify('Clear SSL on all hosts')

          hosts.each do |host|
            ssldir = on(host, puppet('agent --configprint ssldir')).stdout.strip
            # It's important that we leave the ssldir itself intact (although
            # empty) to preserve permissions.
            on(host, "rm -rf #{ssldir}/*")
          end

          # Start puppetserver again and set up intermediate CA if necessary
          logger.notify('Start puppetserver')

          master_fqdn = on(master, 'facter fqdn').stdout.strip
          master_hostname = on(master, 'hostname').stdout.strip

          master_puppet_conf = {
            main: {
              dns_alt_names: "puppet,#{master_hostname},#{master_fqdn}",
              server: master_fqdn
            }
          }

          on(master, 'puppetserver ca setup') if use_intermediate_ca

          with_puppet_running_on(master, master_puppet_conf) do
            logger.notify('Run agent --test on agents to generate CSRs')

            block_on(hosts) do |agent|
              next if agent == master
              on(agent, puppet("agent --test --server #{master}"), acceptable_exit_codes: [1])
            end

            logger.notify('Sign all certs')

            if use_intermediate_ca
              on(master, 'puppetserver ca sign --all', acceptable_exit_codes: [0, 24])
            else
              on(master, puppet('cert sign --all'), acceptable_exit_codes: [0, 24])
            end

            logger.notify("Run agent --test on agents a second time to obtain signed certs ")

            block_on(hosts) do |agent|
              next if agent == master
              on(agent, puppet("agent --test --server #{master}"), acceptable_exit_codes: [0, 2])
            end
          end
        end

        # Make all agents generate CSRs and make the master sign them
        def sign_agent_certs
          sign_agent_cert_for(hosts)
        end

        #If the host is associated with a type remove all defaults and environment associated with that type.
        # @param [Host, Array<Host>, String, Symbol] hosts    One or more hosts to act upon,
        #                            or a role (String or Symbol) that identifies one or more hosts.
        def remove_defaults_on( hosts )
          block_on hosts do |host|
            if host['type']
              # clean up the naming conventions here (some teams use foss-package, git-whatever, we need
              # to correctly handle that
              # don't worry about aio, that happens in the aio_version? check
              host_type = normalize_type(host['type'])
              remove_puppet_paths_on(hosts)
              remove_method = "remove_#{host_type}_defaults_on"
              if self.respond_to?(remove_method, host)
                self.send(remove_method, host)
              else
                raise "cannot remove defaults of type #{host_type} associated with host #{host.name} (#{remove_method} not present)"
              end
              if aio_version?(host)
                remove_aio_defaults_on(host)
              end
            end
          end
        end

        # Uses puppet to stop the firewall on the given hosts. Puppet must be installed before calling this method.
        # @param [Host, Array<Host>, String, Symbol] hosts One or more hosts to act upon, or a role (String or Symbol) that identifies one or more hosts.
        def stop_firewall_with_puppet_on(hosts)
          block_on hosts do |host|
            case host['platform']
            when /debian/
              result = on(host, 'which iptables', accept_all_exit_codes: true)
              if result.exit_code == 0
                on host, 'iptables -F'
              else
                logger.notify("Unable to locate `iptables` on #{host['platform']}; not attempting to clear firewall")
              end
            when /fedora|el-7/
              on host, puppet('resource', 'service', 'firewalld', 'ensure=stopped')
            when /el-|centos/
              on host, puppet('resource', 'service', 'iptables', 'ensure=stopped')
            when /ubuntu/
              on host, puppet('resource', 'service', 'ufw', 'ensure=stopped')
            else
              logger.notify("Not sure how to clear firewall on #{host['platform']}")
            end
          end
        end
      end
    end
  end
end
