# frozen_string_literal: true

require 'kubeclient'
require 'yaml'
require 'tempfile'
require 'base64'

module Beaker
  # Helper class for KubeVirt operations
  class KubevirtHelper
    attr_reader :namespace, :options, :k8s_client, :kubevirt_client

    def initialize(options)
      @options = options
      @namespace = options[:namespace] || 'default'
      @kubeconfig_path = options[:kubeconfig] || ENV['KUBECONFIG'] || File.join(Dir.home, '.kube', 'config')
      @kubecontext = options[:kubecontext] || ENV.fetch('KUBECONTEXT', nil)
      @logger = options[:logger]

      # Allow injection of clients for testing
      @k8s_client = options[:k8s_client]
      @kubevirt_client = options[:kubevirt_client]

      # Only setup clients if not provided (for testing)
      return if @k8s_client && @kubevirt_client

      setup_clients
    end

    ##
    # Setup Kubernetes and KubeVirt clients
    def setup_clients
      setup_kubernetes_client
      setup_kubevirt_client
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
      vms = @kubevirt_client.get_virtual_machines(namespace: @namespace,
                                                  label_selector: "beaker/test-group=#{test_group_identifier}")
      vms.each do |vm|
        @kubevirt_client.delete_virtual_machine(vm.metadata.name, @namespace)
        @logger.debug("Deleted VM #{vm.metadata.name} for test group #{test_group_identifier}")
      rescue Kubeclient::ResourceNotFoundError
        @logger.debug("VM #{vm.metadata.name} not found during cleanup for test group #{test_group_identifier}")
      end
    end

    ##
    # Cleanup secrets associated with a test group
    # @param [String] test_group_identifier The identifier for the test group
    def cleanup_secrets(test_group_identifier)
      @logger.info("Cleaning up secrets for test group: #{test_group_identifier}")
      secrets = @k8s_client.get_secrets(namespace: @namespace,
                                        label_selector: "beaker/test-group=#{test_group_identifier}")
      secrets.each do |secret|
        @k8s_client.delete_secret(secret.metadata.name, @namespace)
        @logger.debug("Deleted secret #{secret.metadata.name} for test group #{test_group_identifier}")
      rescue Kubeclient::ResourceNotFoundError
        @logger.debug("Secret #{secret.metadata.name} not found during cleanup for test group #{test_group_identifier}")
      end
    end

    ##
    # Cleanup services associated with a test group
    # @param [String] test_group_identifier The identifier for the test group
    def cleanup_services(test_group_identifier)
      @logger.info("Cleaning up services for test group: #{test_group_identifier}")
      services = @k8s_client.get_services(namespace: @namespace,
                                          label_selector: "beaker/test-group=#{test_group_identifier}")
      services.each do |service|
        @k8s_client.delete_service(service.metadata.name, @namespace)
        @logger.debug("Deleted service #{service.metadata.name} for test group #{test_group_identifier}")
      rescue Kubeclient::ResourceNotFoundError
        @logger.debug("Service #{service.metadata.name} not found during cleanup for test group #{test_group_identifier}")
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
      )

      # Start the port forwarder in a background thread
      forwarder.start

      # Check if the forwarder started correctly.
      return if forwarder.state == :running

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
    # @return [Hash] Service object
    def create_nodeport_service(vm_name, service_name)
      service_spec = {
        'apiVersion' => 'v1',
        'kind' => 'Service',
        'metadata' => {
          'name' => service_name,
          'namespace' => @namespace,
          'labels' => {
            'beaker/vm' => vm_name,
          },
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

    ##
    # Get service by name
    # @param [String] service_name The service name
    # @return [Hash] Service object
    def get_service(service_name)
      @k8s_client.get_service(service_name, @namespace)
    rescue Kubeclient::ResourceNotFoundError
      nil
    end

    private

    ##
    # Setup Kubernetes API client
    def setup_kubernetes_client
      config = Kubeclient::Config.read(@kubeconfig_path)
      context_config = config.context(@kubecontext)
      @k8s_client = Kubeclient::Client.new(
        context_config.api_endpoint,
        'v1',
        ssl_options: context_config.ssl_options,
        auth_options: context_config.auth_options,
      )
    rescue StandardError => e
      # For testing or when Kubeclient can't parse, fall back to manual parsing
      @logger&.debug("Failed to use Kubeclient::Config, falling back to manual parsing: #{e.message}")
      setup_kubernetes_client_manual
    end

    ##
    # Setup KubeVirt API client
    def setup_kubevirt_client
      config = Kubeclient::Config.read(@kubeconfig_path)
      context_config = config.context(@kubecontext)
      @kubevirt_client = Kubeclient::Client.new(
        "#{context_config.api_endpoint}/apis/kubevirt.io",
        'v1',
        ssl_options: context_config.ssl_options,
        auth_options: context_config.auth_options,
      )
    rescue StandardError => e
      # For testing or when Kubeclient can't parse, fall back to manual parsing
      @logger&.debug("Failed to use Kubeclient::Config, falling back to manual parsing: #{e.message}")
      setup_kubevirt_client_manual
    end

    ##
    # Setup Kubernetes API client using manual kubeconfig parsing
    def setup_kubernetes_client_manual
      config = load_kubeconfig
      context_config = get_context_config(config)
      ssl_options = setup_ssl_options(context_config)
      auth_options = setup_auth_options(context_config)

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
      raise "Kubeconfig file not found: #{@kubeconfig_path}" unless File.exist?(@kubeconfig_path)

      YAML.safe_load(File.read(@kubeconfig_path))
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
      file = Tempfile.new(prefix)
      file.write(content)
      file.close
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
