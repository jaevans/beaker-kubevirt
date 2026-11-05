# frozen_string_literal: true

RSpec.describe Beaker::KubevirtHelper do
  let(:options) do
    {
      logger: instance_double(Logger).as_null_object,
      kubeconfig: '/tmp/test-kubeconfig',
      namespace: 'test-namespace',
      k8s_client: instance_double(Kubeclient::Client),
      kubevirt_client: instance_double(Kubeclient::Client),
    }
  end

  let(:options_without_clients) do
    {
      logger: instance_double(Logger).as_null_object,
      kubeconfig: '/tmp/test-kubeconfig',
      namespace: 'test-namespace',
    }
  end

  let(:mock_config) do
    {
      'apiVersion' => 'v1',
      'kind' => 'Config',
      'current-context' => 'test-context',
      'contexts' => [
        {
          'name' => 'test-context',
          'context' => {
            'cluster' => 'test-cluster',
            'user' => 'test-user',
          },
        },
      ],
      'clusters' => [
        {
          'name' => 'test-cluster',
          'cluster' => {
            'server' => 'https://kubernetes.example.com:6443',
            'certificate-authority-data' => Base64.strict_encode64('fake-ca-cert'),
          },
        },
      ],
      'users' => [
        {
          'name' => 'test-user',
          'user' => {
            'token' => 'fake-token',
          },
        },
      ],
    }
  end

  describe '#initialize' do
    context 'when setting up' do
      let(:helper) { described_class.new(options) }

      it 'sets the namespace' do
        expect(helper.namespace).to eq('test-namespace')
      end

      it 'sets the options' do
        expect(helper.options).to eq(options)
      end
    end

    it 'defaults to default namespace' do
      opts = options.dup
      opts.delete(:namespace)
      helper = described_class.new(opts)

      expect(helper.namespace).to eq('default')
    end

    context 'when clients are injected' do
      let(:helper) { described_class.new(options) }

      it 'uses the injected k8s client' do
        expect(helper.k8s_client).to be(options[:k8s_client])
      end

      it 'uses the injected kubevirt client' do
        expect(helper.kubevirt_client).to be(options[:kubevirt_client])
      end
    end

    context 'when clients are not injected' do
      let(:clients) do
        {
          k8s: instance_double(Kubeclient::Client),
          kubevirt: instance_double(Kubeclient::Client),
        }
      end
      let(:helper) { described_class.new(options_without_clients) }

      before do
        allow(File).to receive(:exist?).with('/tmp/test-kubeconfig').and_return(true)
        allow(File).to receive(:file?).with('/tmp/test-kubeconfig').and_return(true)
        allow(File).to receive(:symlink?).with('/tmp/test-kubeconfig').and_return(false)
        allow(YAML).to receive(:safe_load_file).with('/tmp/test-kubeconfig').and_return(mock_config)
        allow(Kubeclient::Client).to receive(:new).and_return(clients[:k8s], clients[:kubevirt])
      end

      it 'sets up the k8s client' do
        expect(helper.k8s_client).to be(clients[:k8s])
      end

      it 'sets up the kubevirt client' do
        expect(helper.kubevirt_client).to be(clients[:kubevirt])
      end
    end
  end

  describe '#load_kubeconfig' do
    let(:helper) { described_class.new(options) }

    before do
      allow(File).to receive(:exist?).with('/tmp/test-kubeconfig').and_return(true)
      allow(File).to receive(:file?).with('/tmp/test-kubeconfig').and_return(true)
      allow(File).to receive(:symlink?).with('/tmp/test-kubeconfig').and_return(false)
      allow(YAML).to receive(:safe_load_file).with('/tmp/test-kubeconfig').and_return(mock_config)
    end

    it 'loads kubeconfig from specified path' do
      config = helper.send(:load_kubeconfig)
      expect(config).to eq(mock_config)
    end

    it 'raises error if kubeconfig does not exist' do
      allow(File).to receive(:exist?).with('/tmp/test-kubeconfig').and_return(false)

      expect { helper.send(:load_kubeconfig) }.to raise_error(/Kubeconfig file not found/)
    end
  end

  describe '#get_context_config' do
    let(:helper) { described_class.new(options) }
    let(:context_config) { helper.send(:get_context_config, mock_config) }

    it 'returns the cluster server' do
      expect(context_config['cluster']['server']).to eq('https://kubernetes.example.com:6443')
    end

    it 'returns the user token' do
      expect(context_config['user']['token']).to eq('fake-token')
    end

    it 'raises error for missing context' do
      config = mock_config.dup
      config['current-context'] = 'missing-context'

      expect { helper.send(:get_context_config, config) }.to raise_error(/Context 'missing-context' not found/)
    end
  end

  describe '#setup_ssl_options' do
    let(:helper) { described_class.new(options) }
    let(:context_config) do
      {
        'cluster' => {
          'certificate-authority-data' => Base64.strict_encode64('fake-ca-cert'),
        },
      }
    end

    it 'sets up SSL options with CA data' do
      allow(helper).to receive(:write_temp_file).and_return('/tmp/ca-cert')

      ssl_options = helper.send(:setup_ssl_options, context_config)

      expect(ssl_options[:ca_file]).to eq('/tmp/ca-cert')
    end

    it 'handles insecure skip TLS verify' do
      context_config['cluster']['insecure-skip-tls-verify'] = true

      ssl_options = helper.send(:setup_ssl_options, context_config)

      expect(ssl_options[:verify_ssl]).to be false
    end
  end

  describe '#setup_auth_options' do
    let(:helper) { described_class.new(options) }

    context 'with token auth' do
      let(:context_config) do
        { 'user' => { 'token' => 'test-token' } }
      end

      it 'sets up bearer token auth' do
        auth_options = helper.send(:setup_auth_options, context_config)
        expect(auth_options[:bearer_token]).to eq('test-token')
      end
    end

    context 'with client certificate auth' do
      let(:context_config) do
        {
          'user' => {
            'client-certificate-data' => Base64.strict_encode64('fake-cert'),
            'client-key-data' => Base64.strict_encode64('fake-key'),
          },
        }
      end

      it 'sets up client certificate auth' do
        allow(helper).to receive(:write_temp_file).and_return('/tmp/cert', '/tmp/key')
        auth_options = helper.send(:setup_auth_options, context_config)
        expect(auth_options[:client_cert]).to eq('/tmp/cert')
      end

      it 'sets up client key auth' do
        allow(helper).to receive(:write_temp_file).and_return('/tmp/cert', '/tmp/key')
        auth_options = helper.send(:setup_auth_options, context_config)
        expect(auth_options[:client_key]).to eq('/tmp/key')
      end
    end
  end

  describe '#get_virt_launcher_pod' do
    let(:k8s_client) { double('k8s_client') }
    let(:helper) { described_class.new(options.merge(k8s_client: k8s_client)) }

    def launcher(name, created, deleting: nil)
      metadata = { 'name' => name, 'creationTimestamp' => created }
      metadata['deletionTimestamp'] = deleting if deleting
      { 'metadata' => metadata }
    end

    def stub_pods(*pods)
      allow(k8s_client).to receive(:get_pods)
        .with(namespace: 'test-namespace', label_selector: 'kubevirt.io/vm=my-vm')
        .and_return(pods)
    end

    it 'returns nil when no launcher pod exists' do
      stub_pods
      expect(helper.get_virt_launcher_pod('my-vm')).to be_nil
    end

    it 'picks the newest pod regardless of list order' do
      stub_pods(launcher('new', '2026-11-05T19:00:00Z'), launcher('old', '2026-11-05T18:00:00Z'))
      expect(helper.get_virt_launcher_pod('my-vm').dig('metadata', 'name')).to eq('new')
      stub_pods(launcher('old', '2026-11-05T18:00:00Z'), launcher('new', '2026-11-05T19:00:00Z'))
      expect(helper.get_virt_launcher_pod('my-vm').dig('metadata', 'name')).to eq('new')
    end

    it 'skips a newer pod that is terminating in favour of a live one' do
      stub_pods(launcher('live', '2026-11-05T18:00:00Z'),
                launcher('terminating', '2026-11-05T19:00:00Z', deleting: '2026-11-05T19:05:00Z'))
      expect(helper.get_virt_launcher_pod('my-vm').dig('metadata', 'name')).to eq('live')
    end

    it 'falls back to the newest pod when every one is terminating' do
      stub_pods(launcher('old', '2026-11-05T18:00:00Z', deleting: '2026-11-05T19:05:00Z'),
                launcher('new', '2026-11-05T19:00:00Z', deleting: '2026-11-05T19:05:00Z'))
      expect(helper.get_virt_launcher_pod('my-vm').dig('metadata', 'name')).to eq('new')
    end

    it 'works on the RecursiveOpenStruct objects kubeclient returns by default' do
      stub_pods(RecursiveOpenStruct.new(launcher('old', '2026-11-05T18:00:00Z'), recurse_over_arrays: true),
                RecursiveOpenStruct.new(launcher('new', '2026-11-05T19:00:00Z'), recurse_over_arrays: true))
      expect(helper.get_virt_launcher_pod('my-vm').dig('metadata', 'name')).to eq('new')
    end

    it 'returns nil when the pod list is not found' do
      allow(k8s_client).to receive(:get_pods).and_raise(Kubeclient::ResourceNotFoundError)
      expect(helper.get_virt_launcher_pod('my-vm')).to be_nil
    end
  end

  describe '#create_nodeport_service' do
    let(:k8s_client) { double('k8s_client') }
    let(:opts) { options.merge(k8s_client: k8s_client) }
    let(:helper) { described_class.new(opts) }

    before do
      allow(k8s_client).to receive(:create_service) { |spec| spec }
    end

    it 'tags the service with both beaker/vm and beaker/test-group labels' do
      spec = helper.create_nodeport_service('my-vm', 'my-vm-ssh', 'beaker-abcd1234')
      labels = spec.dig(:metadata, :labels)
      expect(labels).to include('beaker/vm': 'my-vm', 'beaker/test-group': 'beaker-abcd1234')
    end

    it 'omits the test-group label when none is provided' do
      spec = helper.create_nodeport_service('my-vm', 'my-vm-ssh')
      labels = spec.dig(:metadata, :labels)
      expect(labels).to eq('beaker/vm': 'my-vm')
    end
  end

  describe 'manual kubeconfig parsing fallback' do
    let(:clients) do
      {
        k8s: instance_double(Kubeclient::Client),
        kubevirt: instance_double(Kubeclient::Client),
      }
    end
    let(:options_without_clients) do
      {
        logger: instance_double(Logger).as_null_object,
        kubeconfig: '/tmp/test-kubeconfig',
        namespace: 'test-namespace',
      }
    end
    let(:kubevirt_helper) { described_class.new(options_without_clients) }

    before do
      allow(File).to receive(:exist?).with('/tmp/test-kubeconfig').and_return(true)
      allow(File).to receive(:file?).with('/tmp/test-kubeconfig').and_return(true)
      allow(File).to receive(:symlink?).with('/tmp/test-kubeconfig').and_return(false)
      allow(YAML).to receive(:safe_load_file).with('/tmp/test-kubeconfig').and_return(mock_config)
      allow(Kubeclient::Config).to receive(:read).and_raise(RuntimeError, 'Unknown kubeconfig version')
      allow(Kubeclient::Client).to receive(:new).and_return(clients[:k8s], clients[:kubevirt])
      allow(kubevirt_helper).to receive(:write_temp_file).and_return('/tmp/ca-cert')
    end

    it 'sets up the k8s client' do
      expect(kubevirt_helper.k8s_client).to be(clients[:k8s])
    end

    it 'sets up the kubevirt client' do
      expect(kubevirt_helper.kubevirt_client).to be(clients[:kubevirt])
    end
  end
end
