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
        # Force fallback to manual parsing by making Kubeclient::Config.read fail
        allow(Kubeclient::Config).to receive(:read).and_raise(StandardError.new('Mock failure'))
        allow(File).to receive(:exist?).with('/tmp/test-kubeconfig').and_return(true)
        allow(File).to receive(:read).with('/tmp/test-kubeconfig').and_return(mock_config.to_yaml)

        # Mock Kubeclient::Client.new to return specific clients based on the endpoint
        allow(Kubeclient::Client).to receive(:new) do |endpoint, *_args|
          if endpoint.include?('/apis/kubevirt.io')
            clients[:kubevirt]
          else
            clients[:k8s]
          end
        end

        helper.send(:setup_clients)
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
      allow(File).to receive(:read).with('/tmp/test-kubeconfig').and_return(mock_config.to_yaml)
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
    let(:context_config) do
      {
        'user' => {
          'token' => 'test-token',
          'client-certificate-data' => Base64.strict_encode64('fake-cert'),
          'client-key-data' => Base64.strict_encode64('fake-key'),
        },
      }
    end

    def cert_config
      {
        'user' => {
          'client-certificate-data' => Base64.strict_encode64('fake-cert'),
          'client-key-data' => Base64.strict_encode64('fake-key'),
        },
      }
    end

    it 'sets up bearer token auth' do
      auth_options = helper.send(:setup_auth_options, context_config)
      expect(auth_options[:bearer_token]).to eq('test-token')
    end

    it 'sets up client certificate auth' do
      allow(helper).to receive(:write_temp_file).and_return('/tmp/cert', '/tmp/key')
      auth_options = helper.send(:setup_auth_options, cert_config)
      expect(auth_options[:client_cert]).to eq('/tmp/cert')
    end

    it 'sets up client key auth' do
      allow(helper).to receive(:write_temp_file).and_return('/tmp/cert', '/tmp/key')
      auth_options = helper.send(:setup_auth_options, cert_config)
      expect(auth_options[:client_key]).to eq('/tmp/key')
    end
  end

  describe 'manual kubeconfig parsing fallback' do
    let(:clients) do
      {
        k8s: instance_double(Kubeclient::Client),
        kubevirt: instance_double(Kubeclient::Client),
      }
    end
    let(:helper) { described_class.new(options) }

    before do
      allow(File).to receive(:exist?).with('/tmp/test-kubeconfig').and_return(true)
      allow(File).to receive(:read).with('/tmp/test-kubeconfig').and_return(mock_config.to_yaml)
      allow(Kubeclient::Config).to receive(:read).and_raise(RuntimeError, 'Unknown kubeconfig version')
      allow(Kubeclient::Client).to receive(:new).and_return(clients[:k8s], clients[:kubevirt])
      allow(helper).to receive(:write_temp_file).and_return('/tmp/ca-cert')
      helper.send(:setup_clients)
    end

    it 'sets up the k8s client' do
      expect(helper.k8s_client).to be(clients[:k8s])
    end

    it 'sets up the kubevirt client' do
      expect(helper.kubevirt_client).to be(clients[:kubevirt])
    end
  end
end
