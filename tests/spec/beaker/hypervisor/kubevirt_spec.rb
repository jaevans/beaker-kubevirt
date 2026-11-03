# frozen_string_literal: true

require 'beaker-rspec'
require 'beaker/hypervisor/kubevirt'

describe Beaker::Hypervisor::Kubevirt do
  it 'can run a command' do
    result = on default, 'echo hello'
    expect(result.stdout).to include('hello')
  end
end
