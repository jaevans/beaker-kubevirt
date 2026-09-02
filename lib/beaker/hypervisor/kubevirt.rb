# frozen_string_literal: true

require 'securerandom'
require 'yaml'
require 'base64'
require 'socket'
require 'tempfile'

begin
  require 'beaker'
rescue LoadError
  # If beaker is not available, define a minimal Hypervisor base class
  module Beaker
    # Beaker support for the KubeVirt virtualization platform.
    #
    # This class implements a Beaker hypervisor driver for managing virtual machines
    # on a KubeVirt-enabled Kubernetes cluster. It provides methods for provisioning,
    # configuring, and cleaning up VMs, as well as handling networking and SSH access.
    #
    # The class expects to be initialized with a list of host definitions and an options hash.
    # It supports multiple network modes (port-forward, nodeport, multus) and integrates
    # with KubeVirt's APIs for VM lifecycle management.
    #
    # @see https://kubevirt.io/ KubeVirt Documentation
    # @see https://github.com/voxpupuli/beaker Beaker Documentation
    class Hypervisor
      def initialize(hosts, options)
        @hosts = hosts
        @options = options
      end
    end
  end
end

module Beaker
  # Beaker support for KubeVirt virtualization platform
  class Kubevirt < Beaker::Hypervisor
    SLEEPWAIT = 5
    SSH_TIMEOUT = 300

    # Default value for BEAKER_destroy environment variable
    DEFAULT_BEAKER_DESTROY = 'yes'
    # Values of BEAKER_destroy that indicate resources should be preserved
    BEAKER_DESTROY_PRESERVE_VALUES = %w[no never onpass].freeze

    # Shared Kubernetes 63-character upper bound used by names/labels in this class.
    K8S_NAME_MAX = 63
    # Kubernetes label-value maximum length under Kubernetes label value constraints (63 chars).
    LABEL_VALUE_MAX = K8S_NAME_MAX

    # RFC 1123 DNS label — same constraint kube-apiserver applies to namespaces.
    NAMESPACE_RE = /\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/

    # VMI phases that indicate the VM will never reach Running.
    VMI_TERMINAL_PHASES = %w[Failed Succeeded].freeze
    # virt-launcher container waiting reasons we treat as fatal.
    FATAL_CONTAINER_WAITING_REASONS = %w[CrashLoopBackOff ImagePullBackOff ErrImagePull].freeze
    # virt-launcher container termination reasons we treat as fatal.
    FATAL_CONTAINER_TERMINATED_REASONS = %w[OOMKilled Error ContainerCannotRun].freeze

    ##
    # Create a new instance of the KubeVirt hypervisor object
    #
    # @param [Array<Host>] kubevirt_hosts The Array of KubeVirt hosts to provision
    # @param [Hash{Symbol=>String}] options The options hash containing configuration values
    #
    # @option options [String] :kubeconfig Path to kubeconfig file
    # @option options [String] :kubecontext Kubernetes context to use (optional)
    # @option options [String] :namespace Kubernetes namespace for VMs (required)
    # @option options [String] :kubevirt_service_account Kubernetes service account to use for PVC access (optional, required for cross-namespace PVC cloning)
    # @option options [String] :kubevirt_vm_image Base VM image (PVC, container image, etc.)
    # @option options [String] :kubevirt_network_mode Network mode (port-forward, nodeport, multus)
    # @option options [String] :kubevirt_ssh_key SSH public key to inject
    # @option options [String] :kubevirt_cpus CPU resources for VM
    # @option options [String] :kubevirt_cpu_request CPU request for the VM pod, as a Kubernetes
    #   CPU quantity ('2', '1500m'). Unset by default, which leaves KubeVirt to derive the request
    #   from the guest core count divided by the cluster's cpuAllocationRatio (default 10). Set it
    #   for guests that must not be throttled while booting -- Windows especially.
    # @option options [String] :kubevirt_cpu_limit CPU limit for the VM pod, as a Kubernetes CPU
    #   quantity. Unset by default, which leaves the compute container burstable.
    # @option options [String] :kubevirt_memory Memory resources for VM
    # @option options [String] :kubevirt_memory_overhead Extra memory added to guest for the
    #   container memory limit (default: '512Mi'). Needed for Windows guests where KubeVirt's
    #   auto-computed virt-launcher overhead is too small and the compute container gets OOMKilled.
    # @option options [String] :kubevirt_memory_request Memory request for the VM pod
    #   (default: same as :kubevirt_memory).
    # @option options [Integer] :kubevirt_vm_ssh_port Port that SSH runs on inside the VM (default: 22)
    # @option options [Boolean] :kubevirt_readiness_probe_disabled Skip the VMI SSH
    #   readinessProbe. Defaults to false for pod-network modes (port-forward, nodeport)
    #   and true for multus (the tcpSocket probe runs from the virt-launcher pod's
    #   network namespace and typically can't reach a bridge-only guest on a secondary NIC).
    # @option options [Hash] :kubevirt_readiness_probe Probe tuning (all optional, snake_case):
    #   :initial_delay_seconds (30), :period_seconds (10), :timeout_seconds (3),
    #   :failure_threshold (60), :success_threshold (1). The default failure budget
    #   (period_seconds * failure_threshold = 600s) accommodates slow Windows first-boots.
    # @option options [Integer] :timeout Timeout for operations. When the readiness probe is
    #   enabled, the effective wait is max(:timeout, probe budget + 60s).
    # @option options [Boolean] :kubevirt_disable_virtio Disable virtio devices (for compatibility with Windows)
    def initialize(kubevirt_hosts, options)
      require 'beaker/hypervisor/kubevirt_helper'

      super
      @options = options
      @namespace = @options[:namespace]
      raise 'Namespace must be specified in options' unless @namespace
      raise ArgumentError, "Invalid namespace #{@namespace.inspect}: must match RFC 1123 DNS label" unless @namespace.is_a?(String) && NAMESPACE_RE.match?(@namespace)

      @service_account = @options[:kubevirt_service_account]

      @logger = options[:logger]
      @hosts = kubevirt_hosts
      # Ensure the helper gets the validated namespace
      @kubevirt_helper = KubevirtHelper.new(@options)
      @test_group_identifier = "beaker-#{SecureRandom.hex(4)}"
      @cleanup_called = false
      @cleanup_mutex = Mutex.new

      # Register at_exit handler to ensure cleanup happens even on non-success exits
      # This handles cases like Ctrl+C, errors, or test failures that occur after
      # provisioning but before normal cleanup
      # Note: Each instance registers its own at_exit handler, but cleanup is idempotent
      # and scoped to the specific test_group_identifier for this instance
      # Skip registration during this gem's own rspec run (set by spec_helper).
      # Gating on `defined?(RSpec)` misfired in downstream projects that run
      # Beaker from inside their own rspec suite, suppressing the safety net
      # for every consumer.
      return if ENV['BEAKER_KUBEVIRT_DISABLE_AT_EXIT_CLEANUP'] == '1'

      at_exit do
        cleanup_on_exit
      end
    end

    ##
    # Create and configure virtual machines in KubeVirt
    def provision
      # rubocop:disable Style/CombinableLoops
      @logger.info("Starting KubeVirt provisioning with identifier: #{@test_group_identifier}")

      @hosts.each do |host|
        create_vm(host)
      rescue StandardError, Interrupt => e
        @logger.error("Error creating VM for host #{host.name}: #{e.message}")
        cleanup
        raise e
      end

      @hosts.each do |host|
        wait_for_vm_ready(host)
        setup_networking(host)
      rescue StandardError, Interrupt => e
        @logger.error("Error provisioning host #{host.name}: #{e.message}")
        @logger.error("Cleaning up host #{host.name} due to provisioning failure")
        cleanup
        raise e
      end
      # rubocop:enable Style/CombinableLoops
    end

    ##
    # Shutdown and destroy virtual machines in KubeVirt
    def cleanup(timeout: 10, delay: 1)
      @cleanup_mutex.synchronize do
        return if @cleanup_called

        @cleanup_called = true
      end

      cleanup_impl(timeout: timeout, delay: delay)
    end

    private

    ##
    # Internal cleanup implementation that performs the actual cleanup work
    # This is separate from cleanup() to avoid mutex issues when called from at_exit
    def cleanup_impl(timeout: 10, delay: 1)
      @logger.info('Cleaning up KubeVirt resources')

      @hosts.each do |host|
        next unless host['port_forwarder']

        host_name = host.respond_to?(:name) ? host.name : host['name']
        @logger.debug("Stopping port-forwarder for host: #{host_name}")
        host['port_forwarder'].stop if host['port_forwarder'].respond_to?(:stop)
        begin
          Timeout.timeout(timeout) do
            loop do
              break if host['port_forwarder'].state == :stopped

              @logger.debug("Waiting for port-forwarder to stop for host: #{host_name}")
              sleep delay
            end
          end
        rescue Timeout::Error
          # Don't let one stuck forwarder block cluster-side cleanup; the
          # forwarder's internal thread-kill path has already bounded the
          # guest-side work by this point.
          @logger.error("Port-forwarder for host #{host_name} did not stop within #{timeout}s; proceeding with cluster-side cleanup anyway")
        rescue StandardError => e
          @logger.error("Error stopping port-forwarder for host #{host_name}: #{e}")
        end
      end

      @logger.info("Cleaning up resources in namespace: #{@namespace}")
      begin
        safe_cleanup('cleaning up VMs') { @kubevirt_helper.cleanup_vms(@test_group_identifier) }
        # DataVolumes (and their backing PVCs) — VMs first so the VMI
        # releases the PVC before the DV delete tries to reclaim storage.
        safe_cleanup('cleaning up DataVolumes') { @kubevirt_helper.cleanup_data_volumes(@test_group_identifier) }
        safe_cleanup('cleaning up secrets') { @kubevirt_helper.cleanup_secrets(@test_group_identifier) }
        safe_cleanup('cleaning up services') { @kubevirt_helper.cleanup_services(@test_group_identifier) }
      ensure
        # Finally unlink the kubeconfig-derived tempfiles — must be last
        # because the preceding cleanups still need them for auth.
        @kubevirt_helper.cleanup_temp_files
      end
    end

    ##
    # Cleanup handler called at exit
    # Only performs cleanup if:
    # - Cleanup hasn't already been called
    # - User hasn't requested to preserve hosts (via BEAKER_destroy=no or preserve_hosts option)
    def cleanup_on_exit
      # Check if user wants to preserve hosts
      # BEAKER_destroy environment variable (no/never/onpass means preserve)
      beaker_destroy = ENV.fetch('BEAKER_destroy', DEFAULT_BEAKER_DESTROY).downcase
      preserve_from_env = BEAKER_DESTROY_PRESERVE_VALUES.include?(beaker_destroy)

      # Check preserve_hosts option (can be set via --preserve-hosts flag)
      preserve_from_option = @options[:preserve_hosts] || false

      if preserve_from_env
        @logger.info("Preserving KubeVirt resources (BEAKER_destroy=#{beaker_destroy})")
        return
      elsif preserve_from_option
        @logger.info('Preserving KubeVirt resources (preserve_hosts option is set)')
        return
      end

      # Atomically check and set cleanup_called flag
      should_cleanup = false
      @cleanup_mutex.synchronize do
        unless @cleanup_called
          @cleanup_called = true
          should_cleanup = true
        end
      end

      return unless should_cleanup

      # Perform cleanup
      @logger.info('at_exit: Performing cleanup of KubeVirt resources')
      begin
        # Call cleanup_impl to avoid the mutex lock in cleanup method
        cleanup_impl
      rescue StandardError => e
        # Log but don't raise - we're already exiting
        @logger.error("Error during at_exit cleanup: #{e.message}")
        @logger.debug(e.backtrace.join("\n"))
      end
    end

    ##
    # Execute a cleanup operation, logging any errors without re-raising them.
    # @param [String] description A short description for the error message
    def safe_cleanup(description)
      yield
    rescue StandardError => e
      @logger.error("Error #{description}: #{e.message}")
    end

    ##
    # Create a single VM for the given host
    # @param [Host] host The host to create a VM for
    def create_vm(host)
      vm_name = generate_vm_name(host)
      host['vm_name'] = vm_name

      # Generate DataVolume name if applicable and store it for consistency
      vm_image = host['kubevirt_vm_image'] || @options[:kubevirt_vm_image]
      if vm_image&.start_with?('http://', 'https://')
        base_name = vm_image.split('/').last
        # Create a unique datavolume name by including the VM name in it
        host['dv_name'] = sanitize_k8s_name("#{vm_name}-#{base_name}-dv")
      elsif vm_image && !vm_image.start_with?('docker://', 'oci://')
        # For PVC sources, we also need to clone to avoid sharing the same disk
        source_pvc = vm_image.sub(%r{^pvc://}, '')
        host['source_pvc'] = source_pvc
        if source_pvc.include?('/')
          _, source_pvc_name = source_pvc.split('/', 2)
        else
          source_pvc_name = source_pvc
        end
        host['dv_name'] = sanitize_k8s_name("#{vm_name}-#{source_pvc_name}")

      end

      cloud_init_data = generate_cloud_init(host)
      cloud_init_secret_name = create_cloud_init_secret(host, cloud_init_data)

      vm_spec = generate_vm_spec(host, vm_name, cloud_init_secret_name)

      @logger.debug("Creating KubeVirt VM #{vm_name} for #{host.name}")
      @kubevirt_helper.create_vm(vm_spec)
      @logger.info("Created KubeVirt VM #{vm_name}")
    end

    ##
    # Create a secret holding the cloud-init data
    # @param [Host] host The host configuration
    # @param [String] cloud_init_data Base64 encoded cloud-init data
    # @return [String] The name of the created secret
    def create_cloud_init_secret(host, cloud_init_data)
      raise 'Cloud-init data must be provided' unless cloud_init_data

      secret_name = "#{host['vm_name']}-cloud-init"
      @logger.debug("Creating cloud-init secret #{secret_name} in namespace #{@namespace}")

      secret_spec = {
        'apiVersion' => 'v1',
        'kind' => 'Secret',
        'metadata' => {
          'name' => secret_name,
          'namespace' => @namespace,
          'labels' => get_labels(host),
        },
        'type' => 'Opaque',
        'data' => {
          'userData' => Base64.strict_encode64(cloud_init_data),
        },
      }

      @kubevirt_helper.create_secret(secret_spec)
      @logger.info("Created cloud-init secret #{secret_name} in namespace #{@namespace}")
      secret_name
    end

    ##
    # Generate a unique VM name
    # @param [Host] host The host
    # @return [String] The generated VM name
    def generate_vm_name(host)
      host_name = host.respond_to?(:name) ? host.name : host['name']
      sanitize_k8s_name("#{@test_group_identifier}-#{host_name}")
    end

    ##
    # Generate cloud-init configuration for the VM
    # @param [Host] host The host configuration
    # @return [String] Base64 encoded cloud-init user data
    def generate_cloud_init(host)
      username = host['user'] || 'beaker'
      ssh_key = find_ssh_public_key

      host_name = host.respond_to?(:name) ? host.name : host['name']

      cloud_init = {
        'hostname' => host_name,
      }

      if host[:platform].include?('windows')
        cloud_init['users'] = [
          {
            'name' => username,
            'primary_group' => 'Administrators',
            'ssh_authorized_keys' => [ssh_key],
            'shell' => 'powershell.exe',
          },
        ]
      else
        cloud_init['users'] = [
          {
            'name' => username,
            'sudo' => 'ALL=(ALL) NOPASSWD:ALL',
            'ssh_authorized_keys' => [ssh_key],
            'shell' => '/bin/bash',
          },
        ]
        cloud_init['ssh_pwauth'] = false
        cloud_init['disable_root'] = false
        cloud_init['chpasswd'] = { 'expire' => false }
      end

      # Add custom cloud-init if provided
      if @options[:cloud_init]
        begin
          custom_init = YAML.safe_load(@options[:cloud_init])
        rescue Psych::SyntaxError => e
          raise ArgumentError, "Invalid cloud-init YAML in kubevirt_cloud_init option: #{e.message}"
        end
        cloud_init = cloud_init.merge(custom_init)
      end
      # It looks like the ssh-key is being wrapped to a new line by default, so we need to ensure it is properly formatted
      cloud_init_yaml = Psych.dump(cloud_init, line_width: -1)
      cloud_init_yaml.gsub!(/^---\n/, '') # Remove YAML document header
      "#cloud-config\n#{cloud_init_yaml}"
    end

    ##
    # Find SSH key pair (public and private keys)
    # @return [Hash] Hash with :public_key (content) and :private_key_path
    def find_ssh_key_pair
      if @options[:kubevirt_ssh_key]
        # If kubevirt_ssh_key is specified, it could be a public key path/content
        ssh_key_value = @options[:kubevirt_ssh_key]
        ssh_key_path = ssh_key_value.match?(%r{^[~/.]}) ? File.expand_path(ssh_key_value) : ssh_key_value
        if File.exist?(ssh_key_path)
          pub_key_path = ssh_key_path
          pub_key_content = File.read(pub_key_path).strip

          # Try to find matching private key
          # Remove .pub extension if present to get private key path
          private_key_path = pub_key_path.sub(/\.pub$/, '')

          raise "Private key not found at #{private_key_path} (matching public key #{pub_key_path})" unless File.exist?(private_key_path)

          { public_key: pub_key_content, private_key_path: private_key_path }
        else
          # It's the public key content directly
          # In this case, we can't determine the private key, so use default
          @logger.warn('SSH public key provided as content, cannot determine private key path. Using default.')
          { public_key: @options[:kubevirt_ssh_key].strip, private_key_path: nil }
        end
      else
        # Try common key types in order of preference
        key_names = %w[id_ed25519 id_ecdsa id_rsa]

        key_names.each do |key_name|
          private_key_path = File.join(Dir.home, '.ssh', key_name)
          pub_key_path = "#{private_key_path}.pub"

          # Check if both private and public keys exist
          if File.exist?(private_key_path) && File.exist?(pub_key_path)
            pub_key_content = File.read(pub_key_path).strip
            return { public_key: pub_key_content, private_key_path: private_key_path }
          end
        end

        raise 'No matching SSH key pair found in ~/.ssh/. Specify with :ssh_key option.'
      end
    end

    # Find SSH public key (for backward compatibility)
    # @return [String] SSH public key content
    def find_ssh_public_key
      find_ssh_key_pair[:public_key]
    end

    def get_labels(host)
      raw_name = host.respond_to?(:name) ? host.name : host['name']
      {
        'beaker/test-group' => @test_group_identifier,
        'beaker/host' => sanitize_k8s_label_value(raw_name),
      }
    end

    ##
    # Sanitize a string to meet Kubernetes' label-value constraints:
    # label values may be empty; otherwise they may be up to 63 characters,
    # contain only [a-zA-Z0-9_.-], and must start and end with an
    # alphanumeric character.
    # Unlike sanitize_k8s_name this preserves dots, underscores, and case —
    # labels allow them and losing that information makes `kubectl -l` lookups
    # by hostname fail.
    def sanitize_k8s_label_value(value)
      cleaned = value.to_s.gsub(/[^-A-Za-z0-9_.]/, '-')
      cleaned = cleaned[0, LABEL_VALUE_MAX]
      cleaned = cleaned.sub(/\A[^A-Za-z0-9]+/, '').sub(/[^A-Za-z0-9]+\z/, '')
      cleaned.empty? ? sanitize_k8s_name(value) : cleaned
    end

    def disk_bus(host)
      # Determine the disk bus type based on host configuration
      if host['kubevirt_disable_virtio']
        'sata'
      else
        'virtio'
      end
    end

    def eth_model(host)
      # Determine the network model based on host configuration
      if host['kubevirt_disable_virtio']
        'e1000'
      else
        'virtio'
      end
    end

    ##
    # Generate the hardware devices specification for the VM
    # @param [Host] host The host configuration
    # @return [Hash] Hardware devices specification
    def generate_hardware_spec(host)
      {
        'disks' => [
          {
            'name' => 'rootdisk',
            'disk' => {
              'bus' => disk_bus(host),
            },
          },
          {
            'name' => 'cidata',
            'disk' => {
              'bus' => 'sata',
            },
          },
        ],
        'interfaces' => [
          {
            'name' => 'default',
            'bridge' => {},
            'model' => eth_model(host),
          },
        ],
        'inputs' => [{
          'bus' => 'usb',
          'type' => 'tablet',
          'name' => 'tablet',
        }],
      }
    end

    ##
    # Generate VM specification for KubeVirt
    # @param [Host] host The host configuration
    # @param [String] vm_name The VM name
    # @param [String] cloud_init_secret Base64 encoded cloud-init data
    # @return [Hash] VM specification
    def generate_vm_spec(host, vm_name, cloud_init_secret)
      cpu = host['kubevirt_cpus'] || @options[:kubevirt_cpus] || '1'
      memory = host['kubevirt_memory'] || @options[:kubevirt_memory] || '2Gi'
      # If the memory is a plain number, assume MiB
      memory = "#{memory}Mi" if /^\d+$/.match?(memory)

      overhead = host['kubevirt_memory_overhead'] || @options[:kubevirt_memory_overhead] || '512Mi'
      overhead = "#{overhead}Mi" if /\A\d+\z/.match?(overhead.to_s)
      memory_request = host['kubevirt_memory_request'] || @options[:kubevirt_memory_request] || memory
      memory_request = "#{memory_request}Mi" if /\A\d+\z/.match?(memory_request.to_s)
      memory_limit = "#{parse_memory_mib(memory) + parse_memory_mib(overhead)}Mi"

      # Both unset by default: KubeVirt then derives the pod's CPU request from the guest core
      # count divided by the cluster's cpuAllocationRatio, and sets no limit at all.
      cpu_request = host['kubevirt_cpu_request'] || @options[:kubevirt_cpu_request]
      cpu_limit = host['kubevirt_cpu_limit'] || @options[:kubevirt_cpu_limit]
      resource_requests = { 'memory' => memory_request }
      resource_requests['cpu'] = cpu_request.to_s if cpu_request
      resource_limits = { 'memory' => memory_limit }
      resource_limits['cpu'] = cpu_limit.to_s if cpu_limit

      vm_image = host['kubevirt_vm_image'] || @options[:kubevirt_vm_image]
      host_name = host.respond_to?(:name) ? host.name : host['name']

      unless vm_image
        raise ArgumentError,
              "kubevirt_vm_image must be specified for host '#{host_name}' " \
              '(set in host configuration or global options)'
      end

      {
        'apiVersion' => 'kubevirt.io/v1',
        'kind' => 'VirtualMachine',
        'metadata' => {
          'name' => vm_name,
          'namespace' => @namespace,
          'labels' => get_labels(host),
        },
        'spec' => {
          'runStrategy' => 'Once',
          'dataVolumeTemplates' => generate_root_volume_dvtemplate(vm_image, host),
          'template' => {
            'metadata' => {
              'labels' => get_labels(host).merge({
                                                   'kubevirt.io/vm' => vm_name,
                                                 }),
            },
            'spec' => {
              'domain' => {
                'cpu' => {
                  'cores' => cpu.to_i,
                  'sockets' => 1,
                  'threads' => 1,
                },
                'memory' => {
                  'guest' => memory.to_s,
                },
                'resources' => {
                  'requests' => resource_requests,
                  'limits' => resource_limits,
                },
                'devices' => generate_hardware_spec(host),
                'features' => {
                  'acpi' => {},
                  # Enable SMM (System Management Mode) for secure boot
                  'smm' => {
                    'enabled' => true,
                  },
                },
                # Set to UEFI boot
                'firmware' => {
                  'bootloader' => {
                    'efi' => {},
                  },
                },
              },
              'hostname' => host_name,
              'networks' => generate_networks_spec(host),
              'readinessProbe' => generate_readiness_probe_spec(host),
              'volumes' => [
                generate_root_volume_spec(vm_image, host),
                {
                  'name' => 'cidata',
                  'cloudInitNoCloud' => {
                    'secretRef' => {
                      'name' => cloud_init_secret,
                    },
                  },
                },
                generate_service_account_volume_spec,
              ].compact,
            }.compact,
          },
        },
      }
    end

    ##
    # Generate networks specification for the VM
    # @param [Host] host The host configuration
    # @return [Array] Networks specification
    def generate_networks_spec(host)
      if host['kubevirt_network_mode'] == 'multus'
        # Multus network configuration
        multus_networks = host['networks'] || []
        multus_networks.map do |net|
          {
            'name' => net['name'],
            'multus' => {
              'networkName' => net['multus_network_name'],
            },
          }
        end
      else
        # Default network configuration
        [{
          'name' => 'default',
          'pod' => {},
        }]
      end
    end

    ##
    # Generate a DataVolume Template for the root disk
    # @param [String] vm_image The VM image specification
    # @param [Host] host The host configuration
    # @return [Array] DataVolumeTemplate specifications
    def generate_root_volume_dvtemplate(vm_image, host)
      # Use the dv_name from the current host, not the last one in the array
      dv_name = host['dv_name']
      return nil unless dv_name

      dv_spec = {
        'metadata' => {
          'name' => dv_name,
          'labels' => get_labels(host),
          'namespace' => @namespace,
        },
        'spec' => {
          'storage' => {
            'accessModes' => ['ReadWriteOnce'], # NOTE: This keeps the VM from being live migrated
          },
        },
      }

      # If a custom service account is specified, add it to the DataVolume spec
      # so it can access the source PVC when required (including cross-namespace clones)
      dv_spec['spec']['serviceAccountName'] = @service_account if @service_account

      # Add storage size only if explicitly set or required (HTTP sources need it)
      if host['disk_size']
        dv_spec['spec']['storage']['resources'] = {
          'requests' => {
            'storage' => host['disk_size'].to_s,
          },
        }
      elsif vm_image.start_with?('http://', 'https://')
        # HTTP sources require a size since there's no source to infer from
        dv_spec['spec']['storage']['resources'] = {
          'requests' => {
            'storage' => '10Gi', # Default size for HTTP sources
          },
        }
      end
      # For PVC clones without explicit size, omit storage.resources to inherit from source

      # Set the appropriate source based on image type
      if vm_image.start_with?('http://', 'https://')
        dv_spec['spec']['source'] = {
          'http' => {
            'url' => vm_image,
          },
        }
      elsif host['source_pvc']
        name = host['source_pvc']
        namespace = @namespace
        namespace, name = host['source_pvc'].split('/', 2) if host['source_pvc'].include?('/')
        # Clone from source PVC
        dv_spec['spec']['source'] = {
          'pvc' => {
            'namespace' => namespace,
            'name' => name,
          },
        }
      end

      [dv_spec]
    end

    ##
    # Generate root volume specification based on image type
    # @param [String] vm_image The VM image specification
    # @param [Host] host The host configuration
    # @return [Hash] Volume specification
    def generate_root_volume_spec(vm_image, host)
      if host['dv_name']
        # Use DataVolume (for HTTP URLs or PVC clones)
        {
          'name' => 'rootdisk',
          'dataVolume' => {
            'name' => host['dv_name'],
          },
        }
      elsif vm_image.start_with?('docker://', 'oci://')
        # Container image
        # KubeVirt supports container images as root disks
        # but we need to ensure the image is available in the cluster
        {
          'name' => 'rootdisk',
          'containerDisk' => {
            'image' => vm_image.sub(%r{^(docker|oci)://}, ''), # Remove protocol prefix
          },
        }
      else
        # Fallback: directly reference PVC (not recommended, kept for compatibility)
        vm_image = vm_image.sub(%r{^pvc://}, '') if vm_image.start_with?('pvc://')
        {
          'name' => 'rootdisk',
          'persistentVolumeClaim' => {
            'claimName' => vm_image,
          },
        }
      end
    end

    ##
    # Wait for VM to be ready and running
    # @param [Host] host The host to wait for
    def wait_for_vm_ready(host)
      vm_name = host['vm_name']
      @logger.info("Waiting for VM #{vm_name} to be ready...")

      probe = generate_readiness_probe_spec(host)
      timeout = effective_ready_timeout(probe)

      begin
        Timeout.timeout(timeout) do
          loop do
            # First, wait for the VM to exist
            vm = @kubevirt_helper.get_vm(vm_name)
            break if vm

            @logger.debug("VM #{vm_name} not found yet, waiting...")
            sleep SLEEPWAIT
          end
          loop do
            # First, check if the VM still exists
            vm = @kubevirt_helper.get_vm(vm_name)
            unless vm
              @logger.error("VM #{vm_name} no longer exists")
              raise "VM #{vm_name} was deleted unexpectedly"
            end

            # Then check if the VM is running
            vmi = @kubevirt_helper.get_vmi(vm_name)
            phase = vmi&.dig('status', 'phase')

            if phase == 'Running' && vmi_ssh_ready?(vmi, probe)
              @logger.debug("VM #{vm_name} is ready")
              break
            end

            raise "VMI #{vm_name} entered terminal phase #{phase} before becoming Ready" if VMI_TERMINAL_PHASES.include?(phase)

            check_virt_launcher_health!(vm_name)

            sleep SLEEPWAIT
          end
        end
      rescue Timeout::Error
        @logger.error("Timeout waiting for VM #{vm_name} to be ready")
        raise
      end
    end

    ##
    # Whether the VMI is fully ready. If a readiness probe is configured,
    # require the KubeVirt-managed `Ready` status condition to be True (that
    # tracks the tcpSocket probe, so sshd is actually listening). Otherwise
    # fall back to phase=Running alone — the historical behavior.
    # @param [Hash] vmi VMI object from the kubevirt API
    # @param [Hash, nil] probe The probe spec, or nil when disabled
    # @return [Boolean]
    def vmi_ssh_ready?(vmi, probe)
      return true if probe.nil?

      condition = Array(vmi&.dig('status', 'conditions'))
                  .find { |c| c['type'] == 'Ready' }
      if condition.nil?
        @logger.debug('VMI has no Ready condition yet, continuing to wait')
        return false
      end
      return true if condition['status'] == 'True'

      @logger.debug("VMI Ready=#{condition['status']} reason=#{condition['reason']} message=#{condition['message']}")
      false
    end

    ##
    # Compute the effective outer Timeout for wait_for_vm_ready. When a probe
    # is configured, the probe's worst-case budget (initial delay + period *
    # failureThreshold) must fit, otherwise a user who left :timeout at the
    # default would see the probe truncated before it can fail legitimately.
    # @param [Hash, nil] probe
    # @return [Integer] seconds
    def effective_ready_timeout(probe)
      base = @options[:timeout] || 300
      return base if probe.nil?

      probe_budget = probe['initialDelaySeconds'] +
                     (probe['periodSeconds'] * probe['failureThreshold']) + 60
      [base, probe_budget].max
    end

    ##
    # Inspect the virt-launcher pod backing a VMI and raise with a specific reason
    # if it has already failed (OOMKilled, image pull errors, crash loops, etc.)
    # so we fail fast instead of waiting the full timeout.
    # @param [String] vm_name
    def check_virt_launcher_health!(vm_name)
      pod = @kubevirt_helper.get_virt_launcher_pod(vm_name)
      return unless pod

      phase = pod.dig('status', 'phase')
      raise "virt-launcher pod for #{vm_name} entered phase #{phase}" if phase == 'Failed'

      statuses = Array(pod.dig('status', 'containerStatuses')) +
                 Array(pod.dig('status', 'initContainerStatuses'))
      statuses.each do |cs|
        name = cs['name']
        waiting_reason = cs.dig('state', 'waiting', 'reason')
        if FATAL_CONTAINER_WAITING_REASONS.include?(waiting_reason)
          raise "virt-launcher container #{name} for #{vm_name} is #{waiting_reason}: " \
                "#{cs.dig('state', 'waiting', 'message')}"
        end

        last_term = cs.dig('lastState', 'terminated') || cs.dig('state', 'terminated')
        reason = last_term && last_term['reason']
        next unless FATAL_CONTAINER_TERMINATED_REASONS.include?(reason)

        hint = (reason == 'OOMKilled' && name == 'compute') ? ' — increase :kubevirt_memory_overhead (default 512Mi)' : ''
        raise "virt-launcher container #{name} for #{vm_name} terminated: #{reason}#{hint}"
      end
    end

    ##
    # The guest-side port SSH listens on, shared between the VMI readiness probe
    # and client-side networking setup so they can never drift apart.
    # @param [Host] host The host configuration
    # @return [Integer] SSH port inside the guest
    def vm_ssh_port(host)
      host['kubevirt_vm_ssh_port'] || @options[:kubevirt_vm_ssh_port] || 22
    end

    ##
    # Whether the SSH readinessProbe should be skipped for this host.
    # Defaults to false for pod-network modes (port-forward, nodeport) and true
    # for multus (the probe runs from the virt-launcher pod's netns and
    # typically can't reach a bridge-only guest on a secondary interface).
    # @param [Host] host The host configuration
    # @return [Boolean]
    def readiness_probe_disabled?(host)
      host_val = host['kubevirt_readiness_probe_disabled']
      return host_val unless host_val.nil?

      opt_val = @options[:kubevirt_readiness_probe_disabled]
      return opt_val unless opt_val.nil?

      (host['kubevirt_network_mode'] || 'port-forward') == 'multus'
    end

    ##
    # Build the KubeVirt readinessProbe hash for a host, or nil if disabled.
    # A tcpSocket probe on the guest's SSH port lets KubeVirt publish a
    # Ready condition once sshd is actually accepting connections — wait_for_vm_ready
    # gates on that condition so Beaker doesn't attempt SSH before the guest is up.
    # Per-host overrides win over global options; snake_case keys map to the
    # camelCase probe fields KubeVirt expects.
    # @param [Host] host The host configuration
    # @return [Hash, nil]
    def generate_readiness_probe_spec(host)
      return nil if readiness_probe_disabled?(host)

      cfg = (@options[:kubevirt_readiness_probe] || {})
            .merge(host['kubevirt_readiness_probe'] || {})
      {
        'tcpSocket' => { 'port' => vm_ssh_port(host) },
        'initialDelaySeconds' => cfg[:initial_delay_seconds] || 30,
        'periodSeconds' => cfg[:period_seconds] || 10,
        'timeoutSeconds' => cfg[:timeout_seconds] || 3,
        'failureThreshold' => cfg[:failure_threshold] || 60,
        'successThreshold' => cfg[:success_threshold] || 1,
      }
    end

    ##
    # Setup networking for the VM
    # @param [Host] host The host to setup networking for
    def setup_networking(host)
      network_mode = host['kubevirt_network_mode'] || 'port-forward'

      case network_mode
      when 'port-forward'
        setup_port_forward(host, vm_ssh_port(host))
      when 'nodeport'
        setup_nodeport(host)
      when 'multus'
        setup_multus_networking(host)
      else
        raise "Unsupported network mode: #{network_mode}"
      end

      # Configure SSH keys - ensure we use the matching private key for the public key
      # that was injected into the VM via cloud-init
      configure_ssh_keys(host)
    end

    ##
    # Setup port-forward networking
    # @param [Host] host The host
    # @param [Integer] host_port The port on the VM to forward to (typically 22 for SSH)
    def setup_port_forward(host, host_port)
      require 'beaker/hypervisor/port_forward'
      vm_name = host['vm_name']

      @options['ssh']['port'] = nil
      local_port = find_free_port

      @logger.info("Using local port #{local_port} for port-forward to VM #{vm_name}")

      host['ip'] = '127.0.0.1' # Port forwarding will use localhost
      host['port'] = nil # Port that clients should connect to (local port)
      # Get current SSH options and modify them
      ssh_options = host['ssh'] || {}
      ssh_options['port'] = local_port
      host['ssh'] = ssh_options

      @logger.debug("Setting up port-forward for VM #{vm_name} from localhost:#{local_port} to VM port #{host_port}")
      @logger.debug("Configured SSH connection: host['ip']=#{host['ip']}, host['port']=#{host['port']}, host['ssh']['port']=#{host['ssh']['port']}")

      # Setup port forwarding from local_port to host_port (22) on the VM
      host['port_forwarder'] = @kubevirt_helper.setup_port_forward(vm_name, host_port, local_port)
    end

    ##
    # Setup NodePort networking
    # @param [Host] host The host
    def setup_nodeport(host)
      vm_name = host['vm_name']
      service_name = "#{vm_name}-ssh"

      @logger.debug("Creating NodePort service for VM #{vm_name}")
      service = @kubevirt_helper.create_nodeport_service(vm_name, service_name, @test_group_identifier)

      node_port = service.dig('spec', 'ports', 0, 'nodePort')
      node_ip = @kubevirt_helper.node_ip

      host['ip'] = node_ip
      host['port'] = node_port
      # Get current SSH options and modify them
      ssh_options = host['ssh'] || {}
      ssh_options['port'] = node_port
      host['ssh'] = ssh_options
      host['service_name'] = service_name
    end

    ##
    # Setup Multus networking (external bridge)
    # @param [Host] host The host
    def setup_multus_networking(host)
      vm_name = host['vm_name']
      @logger.debug("Getting external IP for VM #{vm_name} via Multus")

      # For Multus, we need to wait for the VM to get an external IP
      external_ip = wait_for_external_ip(vm_name)

      host['ip'] = external_ip
      host['port'] = 22
      # Get current SSH options and modify them
      ssh_options = host['ssh'] || {}
      ssh_options['port'] = 22
      host['ssh'] = ssh_options
    end

    ##
    # Configure SSH keys for the host
    # Ensures the private key used for SSH matches the public key injected via cloud-init
    # @param [Host] host The host to configure
    def configure_ssh_keys(host)
      ssh_options = host['ssh'] || {}

      # Keep idle SSH sessions alive: long-running commands with no output
      # otherwise hit kube-apiserver / port-forward proxy / NAT idle timeouts.
      ssh_options['keepalive']          = true unless ssh_options.key?('keepalive')
      ssh_options['keepalive_interval'] = 60   unless ssh_options.key?('keepalive_interval')
      ssh_options['keepalive_maxcount'] = 5    unless ssh_options.key?('keepalive_maxcount')

      key_pair = find_ssh_key_pair

      # Only set the private key path if we found a matching pair
      if key_pair[:private_key_path]
        # Prepend the matching key, preserve any pre-existing keys so fallbacks
        # (agent-forwarded, project-wide CI key) still work if ours is unusable.
        existing_keys = Array(ssh_options['keys'])
        merged_keys = [key_pair[:private_key_path]] + existing_keys
        merged_keys.uniq!
        ssh_options['keys'] = merged_keys

        @logger.info("Configured SSH to use private key #{File.basename(key_pair[:private_key_path])}")
        @logger.debug("SSH private key full path: #{key_pair[:private_key_path]}")
      else
        @logger.warn('Could not determine private key path, SSH will use default keys')
      end

      host['ssh'] = ssh_options
    end

    ##
    # Wait for VM to get external IP via Multus
    # @param [String] vm_name The VM name
    # @return [String] External IP address
    def wait_for_external_ip(vm_name)
      timeout = @options[:timeout] || 300
      start_time = Time.now

      loop do
        vmi = @kubevirt_helper.get_vmi(vm_name)
        interfaces = vmi.dig('status', 'interfaces')

        external_interface = interfaces.find { |iface| iface['name'] != 'default' }
        return external_interface['ipAddress'] if external_interface && external_interface['ipAddress']

        raise "Timeout waiting for external IP for VM #{vm_name}" if Time.now - start_time > timeout

        sleep SLEEPWAIT
      end
    end

    ##
    # Find a free local port for port forwarding
    # @return [Integer] Free port number
    def find_free_port
      server = TCPServer.new(0)
      port = server.addr[1]
      server.close
      port
    end

    ##
    # Sanitize a string to make it RFC 1035 DNS label compliant
    # - Lowercase
    # - Only alphanumeric characters and hyphens
    # - Start with a letter
    # - End with an alphanumeric character
    # - Maximum length of 63 characters
    # @param [String] name The string to sanitize
    # @return [String] RFC 1035 compliant string
    # Parse a memory string ("4Gi", "512Mi", "2048") into an integer number of MiB.
    # @param [String, Integer] value
    # @return [Integer] MiB
    def parse_memory_mib(value)
      s = value.to_s.strip
      case s
      when /\A(\d+)Gi\z/ then Regexp.last_match(1).to_i * 1024
      when /\A(\d+)Mi\z/ then Regexp.last_match(1).to_i
      when /\A(\d+)\z/   then s.to_i
      else
        raise ArgumentError, "Cannot parse memory value #{value.inspect} (expected Gi/Mi suffix or bare MiB)"
      end
    end

    def sanitize_k8s_name(name)
      # Remove invalid characters, replace with hyphens
      sanitized = name.downcase.gsub(/[^a-z0-9-]/, '-')

      # Ensure it starts with a letter
      sanitized = "x#{sanitized}" unless /[a-z]/.match?(sanitized[0])

      # Ensure it doesn't end with a hyphen
      sanitized = "#{sanitized}0" if sanitized[-1] == '-'

      # Ensure it's not too long (max 63 chars for DNS label)
      sanitized = sanitized[0..62] if sanitized.length > 63

      sanitized
    end

    ##
    # Generate a service account volume specification if a service account is set.
    # This defines a volume that can be used to attach the configured service account
    # to the VM pod; it is independent of any use of service accounts in DataVolumes.
    # @return [Hash, nil] Service account volume specification or nil
    def generate_service_account_volume_spec
      return nil unless @service_account

      {
        'name' => 'service-account-volume',
        'serviceAccount' => {
          'serviceAccountName' => @service_account,
        },
      }
    end
  end
end
