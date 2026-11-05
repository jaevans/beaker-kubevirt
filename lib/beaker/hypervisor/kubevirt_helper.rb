# frozen_string_literal: true

require 'kubeclient'
require 'yaml'
require 'tempfile'
require 'base64'

module Beaker
  # Helper class for KubeVirt operations
  class KubevirtHelper
    attr_reader :namespace, :options, :k8s_client, :kubevirt_client, :cdi_client

    def initialize(options)
      @options = options
      @namespace = options[:namespace] || 'default'
      raw_kubeconfig = options[:kubeconfig] || ENV['KUBECONFIG'] || File.join(Dir.home, '.kube', 'config')
      @kubeconfig_path = File.expand_path(raw_kubeconfig)
      @kubecontext = options[:kubecontext] || ENV.fetch('KUBECONTEXT', nil)
      @logger = options[:logger]

      # Store original SSL options for port forwarding (before kubeclient processes them)
      @original_ssl_options = nil

      # Keep temp files alive to prevent garbage collection
      @temp_files = []

      # Allow injection of clients for testing
      @k8s_client = options[:k8s_client]
      @kubevirt_client = options[:kubevirt_client]
      @cdi_client = options[:cdi_client]

      # Only setup clients if not provided (for testing)
      return if @k8s_client && @kubevirt_client

      # Manually extract SSL options with CA file by parsing kubeconfig directly
      # (Kubeclient context doesn't expose the raw CA file path/data)
      @original_ssl_options = extract_ssl_from_kubeconfig
      setup_kubernetes_client
      setup_kubevirt_client
      setup_cdi_client unless @cdi_client
    end

    ##
    # Create a virtual machine
    # @param [Hash] vm_spec The VM specification
    def create_vm(vm_spec)
      # Convert all keys to symbols recursively
      vm_spec_sym = symbolize_keys(vm_spec)
      @kubevirt_client.create_virtual_machine(vm_spec_sym)
    end

    ##
    # Create a secret
    # @param [Hash] secret_spec The secret specification
    def create_secret(secret_spec)
      # Convert all keys to symbols recursively
      secret_spec_sym = symbolize_keys(secret_spec)
      @k8s_client.create_secret(secret_spec_sym)
    end

    ##
    # Get a virtual machine
    # @param [String] vm_name The VM name
    # @return [Hash] VM object
    def get_vm(vm_name)
      @kubevirt_client.get_virtual_machine(vm_name, @namespace)
    rescue Kubeclient::ResourceNotFoundError
      nil
    end

    ##
    # Get a virtual machine instance
    # @param [String] vmi_name The VMI name
    # @return [Hash] VMI object
    def get_vmi(vmi_name)
      @kubevirt_client.get_virtual_machine_instance(vmi_name, @namespace)
    rescue Kubeclient::ResourceNotFoundError
      nil
    end

    ##
    # Get the virt-launcher pod backing a VMI. A terminating launcher and its
    # replacement, or a migration's source and target, can match at once, and the
    # list has no guaranteed order, so pick the newest pod that is not being
    # deleted, falling back to the newest overall when every one is terminating.
    # @param [String] vmi_name The VMI name (== VM name)
    # @return [Hash, nil] pod object, or nil if none exists yet
    def get_virt_launcher_pod(vmi_name)
      pods = Array(@k8s_client.get_pods(namespace: @namespace,
                                        label_selector: "kubevirt.io/vm=#{vmi_name}"))
      live = pods.reject { |pod| pod.dig('metadata', 'deletionTimestamp') }
      (live.empty? ? pods : live).max_by { |pod| pod.dig('metadata', 'creationTimestamp').to_s }
    rescue Kubeclient::ResourceNotFoundError
      nil
    end

    ##
    # Delete a virtual machine
    # @param [String] vm_name The VM name
    def delete_vm(vm_name)
      @kubevirt_client.delete_virtual_machine(vm_name, @namespace)
      @logger.debug("Deleted VM #{vm_name}")
    rescue Kubeclient::ResourceNotFoundError
      @logger.debug("VM #{vm_name} not found during deletion")
    end

    ##
    # Cleanup VMs created by this test group
    # @param [String] test_group_identifier The identifier for the test group
    def cleanup_vms(test_group_identifier)
      @logger.info("Cleaning up VMs for test group: #{test_group_identifier}")
      label_selector = "beaker/test-group=#{test_group_identifier}"
      @logger.debug("Using label selector: #{label_selector}")

      vms = @kubevirt_client.get_virtual_machines(namespace: @namespace,
                                                  label_selector: label_selector)
      @logger.info("Found #{vms.length} VM(s) with label beaker/test-group=#{test_group_identifier}")

      vms.each do |vm|
        # Extract VM name - access hash-style to avoid RSpec metadata collision
        vm_metadata = vm[:metadata] || vm['metadata']
        vm_name = vm_metadata[:name] || vm_metadata['name'] if vm_metadata

        unless vm_name && !vm_name.empty?
          @logger.error('Cannot delete VM with empty or nil name.')
          @logger.error("VM structure: #{vm.inspect[0..1000]}")
          next
        end

        vm_labels = vm_metadata[:labels] || vm_metadata['labels'] if vm_metadata
        @logger.debug("Deleting VM #{vm_name} with labels: #{vm_labels.inspect}")
        @kubevirt_client.delete_virtual_machine(vm_name, @namespace)
        @logger.info("Deleted VM #{vm_name}")
      rescue Kubeclient::ResourceNotFoundError
        @logger.debug("VM #{vm_name} not found during cleanup")
      rescue StandardError => e
        @logger.error("Error deleting VM #{vm_name}: #{e.message}")
        @logger.error("Backtrace: #{e.backtrace[0..5].join("\n")}")
      end
    end

    ##
    # Cleanup secrets associated with a test group
    # @param [String] test_group_identifier The identifier for the test group
    def cleanup_secrets(test_group_identifier)
      @logger.info("Cleaning up secrets for test group: #{test_group_identifier}")
      label_selector = "beaker/test-group=#{test_group_identifier}"
      @logger.debug("Using label selector: #{label_selector}")

      secrets = @k8s_client.get_secrets(namespace: @namespace,
                                        label_selector: label_selector)
      @logger.info("Found #{secrets.length} secret(s) with label beaker/test-group=#{test_group_identifier}")

      secrets.each do |secret|
        # Extract secret name - access hash-style to avoid RSpec metadata collision
        secret_metadata = secret[:metadata] || secret['metadata']
        secret_name = secret_metadata[:name] || secret_metadata['name'] if secret_metadata

        unless secret_name && !secret_name.empty?
          @logger.error('Cannot delete secret with empty or nil name.')
          @logger.error("Secret structure: #{secret.inspect[0..1000]}")
          next
        end

        secret_labels = secret_metadata[:labels] || secret_metadata['labels'] if secret_metadata
        @logger.debug("Deleting secret #{secret_name} with labels: #{secret_labels.inspect}")
        @k8s_client.delete_secret(secret_name, @namespace)
        @logger.info("Deleted secret #{secret_name}")
      rescue Kubeclient::ResourceNotFoundError
        @logger.debug("Secret #{secret_name} not found during cleanup")
      rescue StandardError => e
        @logger.error("Error deleting secret #{secret_name}: #{e.message}")
      end
    end

    ##
    # Cleanup services associated with a test group
    # @param [String] test_group_identifier The identifier for the test group
    def cleanup_services(test_group_identifier)
      @logger.info("Cleaning up services for test group: #{test_group_identifier}")
      label_selector = "beaker/test-group=#{test_group_identifier}"
      @logger.debug("Using label selector: #{label_selector}")

      services = @k8s_client.get_services(namespace: @namespace,
                                          label_selector: label_selector)
      @logger.info("Found #{services.length} service(s) with label beaker/test-group=#{test_group_identifier}")

      services.each do |service|
        # Extract service name - access hash-style to avoid RSpec metadata collision
        service_metadata = service[:metadata] || service['metadata']
        service_name = service_metadata[:name] || service_metadata['name'] if service_metadata

        unless service_name && !service_name.empty?
          @logger.error('Cannot delete service with empty or nil name.')
          @logger.error("Service structure: #{service.inspect[0..1000]}")
          next
        end

        service_labels = service_metadata[:labels] || service_metadata['labels'] if service_metadata
        @logger.debug("Deleting service #{service_name} with labels: #{service_labels.inspect}")
        @k8s_client.delete_service(service_name, @namespace)
        @logger.info("Deleted service #{service_name}")
      rescue Kubeclient::ResourceNotFoundError
        @logger.debug("Service #{service_name} not found during cleanup")
      rescue StandardError => e
        @logger.error("Error deleting service #{service_name}: #{e.message}")
      end
    end

    ##
    # Cleanup DataVolumes associated with a test group. No-op if CDI isn't
    # available on the cluster (the @cdi_client stays nil in that case).
    # @param [String] test_group_identifier The identifier for the test group
    def cleanup_data_volumes(test_group_identifier)
      return unless @cdi_client

      @logger.info("Cleaning up DataVolumes for test group: #{test_group_identifier}")
      label_selector = "beaker/test-group=#{test_group_identifier}"

      begin
        dvs = @cdi_client.get_data_volumes(namespace: @namespace, label_selector: label_selector)
      rescue StandardError => e
        @logger.warn("Failed to list DataVolumes for cleanup: #{e.class}: #{e.message}")
        return
      end

      @logger.info("Found #{dvs.length} DataVolume(s) with label #{label_selector}")

      dvs.each do |dv|
        md = dv[:metadata] || dv['metadata']
        dv_name = md[:name] || md['name'] if md
        unless dv_name && !dv_name.empty?
          @logger.error("Skipping DataVolume with missing name: #{dv.inspect[0, 200]}")
          next
        end

        @cdi_client.delete_data_volume(dv_name, @namespace)
        @logger.info("Deleted DataVolume #{dv_name}")
      rescue Kubeclient::ResourceNotFoundError
        @logger.debug("DataVolume #{dv_name} not found during cleanup")
      rescue StandardError => e
        @logger.error("Error deleting DataVolume #{dv_name}: #{e.message}")
      end
    end

    ##
    # Setup port forwarding for a VM
    # @param [String] vm_name The VM name
    # @param [Integer] vm_port The VM port to forward
    # @param [Integer] local_port The local port to forward to
    # @return [Process] The port-forward process
    def setup_port_forward(vm_name, vm_port, local_port)
      require 'beaker/hypervisor/port_forward'
      forwarder = KubeVirtPortForwarder.new(
        kube_client: @kubevirt_client,
        namespace: @namespace,
        vmi_name: vm_name,
        target_port: vm_port,
        local_port: local_port,
        logger: @logger,
        on_error: method(:forwarder_error_handler),
        ssl_options: @original_ssl_options,
      )

      # Start the port forwarder in a background thread
      forwarder.start

      # Check if the forwarder started correctly.
      return forwarder if forwarder.state == :running

      @logger.error("Port forwarder failed to start for VM #{vm_name} on port #{vm_port}")
      raise "Port forwarder failed to start for VM #{vm_name} on port #{vm_port}"
    end

    def forwarder_error_handler(error)
      @logger.error("Port forwarder error: #{error.message}")
      # Optionally, you can implement retry logic or cleanup here
    end

    ##
    # Create a NodePort service for SSH access
    # @param [String] vm_name The VM name
    # @param [String] service_name The service name
    # @param [String, nil] test_group_identifier Test-group identifier applied as
    #   the +beaker/test-group+ label so +cleanup_services+ can match the
    #   service. When +nil+, only the +beaker/vm+ label is set (legacy behavior).
    # @return [Hash] Service object
    def create_nodeport_service(vm_name, service_name, test_group_identifier = nil)
      labels = { 'beaker/vm' => vm_name }
      labels['beaker/test-group'] = test_group_identifier if test_group_identifier

      service_spec = {
        'apiVersion' => 'v1',
        'kind' => 'Service',
        'metadata' => {
          'name' => service_name,
          'namespace' => @namespace,
          'labels' => labels,
        },
        'spec' => {
          'type' => 'NodePort',
          'selector' => {
            'kubevirt.io/vm' => vm_name,
          },
          'ports' => [
            {
              'name' => 'ssh',
              'port' => 22,
              'targetPort' => 22,
              'protocol' => 'TCP',
            },
          ],
        },
      }

      service_spec_sym = symbolize_keys(service_spec)
      @k8s_client.create_service(service_spec_sym)
    end

    ##
    # Unlink the kubeconfig-derived cert/key tempfiles kept alive for the
    # process lifetime. Safe to call after all API operations that need the
    # files have completed.
    def cleanup_temp_files
      return unless @temp_files

      @temp_files.each do |file|
        path = file.path
        file.close unless file.closed?
        file.unlink
      rescue StandardError => e
        @logger&.warn("Failed to unlink temp file #{path}: #{e.message}")
      end
      @temp_files.clear
    end

    ##
    # Get a cluster node IP address
    # @return [String] Node IP address
    def node_ip
      nodes = @k8s_client.get_nodes
      node = nodes.first

      # Try to get external IP first, fallback to internal IP
      addresses = node.dig('status', 'addresses') || []
      external_ip = addresses.find { |addr| addr['type'] == 'ExternalIP' }
      internal_ip = addresses.find { |addr| addr['type'] == 'InternalIP' }

      if external_ip
        external_ip['address']
      elsif internal_ip
        internal_ip['address']
      else
        raise 'Could not determine node IP address'
      end
    end

    private

    ##
    # Setup Kubernetes API client
    def setup_kubernetes_client
      config = Kubeclient::Config.new(load_kubeconfig, File.dirname(@kubeconfig_path))
      context_config = config.context(@kubecontext)

      @k8s_client = Kubeclient::Client.new(
        context_config.api_endpoint,
        context_config.api_version,
        ssl_options: context_config.ssl_options,
        auth_options: context_config.auth_options,
      )
    rescue StandardError => e
      # For testing or when Kubeclient can't parse, fall back to manual parsing
      @logger&.warn("Failed to use Kubeclient::Config, falling back to manual parsing: #{e.message}")
      setup_kubernetes_client_manual
    end

    ##
    # Setup KubeVirt API client
    def setup_kubevirt_client
      config = Kubeclient::Config.new(load_kubeconfig, File.dirname(@kubeconfig_path))
      context_config = config.context(@kubecontext)

      @kubevirt_client = Kubeclient::Client.new(
        "#{context_config.api_endpoint}/apis/kubevirt.io",
        context_config.api_version,
        ssl_options: context_config.ssl_options,
        auth_options: context_config.auth_options,
      )
    rescue StandardError => e
      # For testing or when Kubeclient can't parse, fall back to manual parsing
      @logger&.warn("Failed to use Kubeclient::Config, falling back to manual parsing: #{e.message}")
      setup_kubevirt_client_manual
    end

    ##
    # Setup CDI (Containerized Data Importer) API client used for managing
    # DataVolumes. Best-effort: clusters without CDI installed will still be
    # able to provision container-disk / direct-PVC VMs. We probe the API
    # group with a `discover` call so that clusters lacking CDI leave
    # @cdi_client nil rather than appearing live and warning on every
    # cleanup.
    def setup_cdi_client
      config = Kubeclient::Config.new(load_kubeconfig, File.dirname(@kubeconfig_path))
      context_config = config.context(@kubecontext)
      client = Kubeclient::Client.new(
        "#{context_config.api_endpoint}/apis/cdi.kubevirt.io",
        'v1beta1',
        ssl_options: context_config.ssl_options,
        auth_options: context_config.auth_options,
      )
      client.discover
      @cdi_client = client
    rescue StandardError => e
      @logger&.debug("CDI client setup skipped: #{e.class}: #{e.message}")
      @cdi_client = nil
    end

    ##
    # Setup Kubernetes API client using manual kubeconfig parsing
    def setup_kubernetes_client_manual
      config = load_kubeconfig
      context_config = get_context_config(config)
      ssl_options = setup_ssl_options(context_config)
      auth_options = setup_auth_options(context_config)

      # Store original SSL options before kubeclient processes them
      @original_ssl_options = ssl_options.dup

      @k8s_client = Kubeclient::Client.new(
        context_config['cluster']['server'],
        'v1',
        ssl_options: ssl_options,
        auth_options: auth_options,
      )
    end

    ##
    # Setup KubeVirt API client using manual kubeconfig parsing
    def setup_kubevirt_client_manual
      config = load_kubeconfig
      context_config = get_context_config(config)
      ssl_options = setup_ssl_options(context_config)
      auth_options = setup_auth_options(context_config)

      # Store original SSL options before kubeclient processes them
      @original_ssl_options = ssl_options.dup

      kubevirt_endpoint = "#{context_config['cluster']['server']}/apis/kubevirt.io"
      @kubevirt_client = Kubeclient::Client.new(
        kubevirt_endpoint,
        'v1',
        ssl_options: ssl_options,
        auth_options: auth_options,
      )
    end

    ##
    # Load kubeconfig file
    # @return [Hash] Parsed kubeconfig
    def load_kubeconfig
      return @kubeconfig_data if @kubeconfig_data
      raise "Kubeconfig file not found: #{@kubeconfig_path}" unless File.exist?(@kubeconfig_path)
      raise "Kubeconfig path is not a regular file: #{@kubeconfig_path}" unless File.file?(@kubeconfig_path)

      @logger&.warn("kubeconfig #{@kubeconfig_path} is a symlink to #{File.realpath(@kubeconfig_path)}") if File.symlink?(@kubeconfig_path)

      @kubeconfig_data = YAML.safe_load_file(@kubeconfig_path)
      @kubeconfig_data
    end

    ##
    # Get context configuration from kubeconfig
    # @param [Hash] config The kubeconfig
    # @return [Hash] Context configuration
    def get_context_config(config)
      current_context = @kubecontext || config['current-context']
      raise 'No current context specified' unless current_context

      context = config['contexts'].find { |ctx| ctx['name'] == current_context }
      raise "Context '#{current_context}' not found" unless context

      cluster_name = context.dig('context', 'cluster')
      user_name = context.dig('context', 'user')

      cluster = config['clusters'].find { |c| c['name'] == cluster_name }
      user = config['users'].find { |u| u['name'] == user_name }

      raise "Cluster '#{cluster_name}' not found" unless cluster
      raise "User '#{user_name}' not found" unless user

      {
        'cluster' => cluster['cluster'],
        'user' => user['user'],
        'namespace' => context.dig('context', 'namespace') || @namespace,
      }
    end

    ##
    # Write content to a temporary file
    # @param [String] prefix File prefix
    # @param [String] content File content
    # @return [String] Path to temporary file
    def write_temp_file(prefix, content)
      file = Tempfile.new([prefix, '.pem'])
      file.binmode
      file.write(content)
      file.flush
      file.close
      # Keep reference to prevent garbage collection and file deletion
      @temp_files << file
      @logger&.debug("Created temp file: #{file.path} (#{content.bytesize} bytes)")
      file.path
    end

    ##
    # Recursively convert hash keys to symbols
    def symbolize_keys(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), memo|
          memo[k.to_sym] = symbolize_keys(v)
        end
      when Array
        obj.map { |v| symbolize_keys(v) }
      else
        obj
      end
    end

    ##
    # Extract SSL options directly from kubeconfig file
    # This preserves the :ca_file path before kubeclient converts it to :cert_store
    # @return [Hash] SSL options with :ca_file preserved
    def extract_ssl_from_kubeconfig
      config = load_kubeconfig
      context_config = get_context_config(config)
      ssl_options = setup_ssl_options(context_config)
      @logger&.debug("Extracted SSL options from kubeconfig: #{ssl_options.keys.join(', ')}")
      ssl_options
    end

    ##
    # Setup SSL options from context config
    # @param [Hash] context_config The context configuration
    # @return [Hash] SSL options for Kubeclient
    def setup_ssl_options(context_config)
      ssl_options = {}
      cluster_config = context_config['cluster']

      if cluster_config['certificate-authority-data']
        ca_cert = Base64.strict_decode64(cluster_config['certificate-authority-data'])
        ca_file_path = write_temp_file('ca-cert', ca_cert)
        ssl_options[:ca_file] = ca_file_path
      elsif cluster_config['certificate-authority']
        ssl_options[:ca_file] = cluster_config['certificate-authority']
      end

      ssl_options[:verify_ssl] = false if cluster_config['insecure-skip-tls-verify']

      ssl_options
    end

    ##
    # Setup auth options from context config
    # @param [Hash] context_config The context configuration
    # @return [Hash] Auth options for Kubeclient
    def setup_auth_options(context_config)
      auth_options = {}
      user_config = context_config['user']

      if user_config['token']
        auth_options[:bearer_token] = user_config['token']
      elsif user_config['tokenFile']
        token_file_path = user_config['tokenFile']
        raise "Token file not found: #{token_file_path}" unless File.exist?(token_file_path)

        auth_options[:bearer_token] = File.read(token_file_path).strip

      elsif user_config['client-certificate-data'] && user_config['client-key-data']
        client_cert = Base64.strict_decode64(user_config['client-certificate-data'])
        client_key = Base64.strict_decode64(user_config['client-key-data'])

        cert_file_path = write_temp_file('client-cert', client_cert)
        key_file_path = write_temp_file('client-key', client_key)

        auth_options[:client_cert] = cert_file_path
        auth_options[:client_key] = key_file_path
      elsif user_config['client-certificate'] && user_config['client-key']
        auth_options[:client_cert] = user_config['client-certificate']
        auth_options[:client_key] = user_config['client-key']
      end

      auth_options
    end
  end
end
