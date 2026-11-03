# frozen_string_literal: true

require_relative 'lib/beaker/kubevirt/version'

Gem::Specification.new do |spec|
  spec.name = 'beaker-kubevirt'
  spec.version = BeakerKubevirt::VERSION
  spec.authors = ['Steven Pritchard', 'James Evans']
  spec.email = ['steven.pritchard@gmail.com']

  spec.summary = 'KubeVirt hypervisor support for Beaker acceptance testing'
  spec.description = 'Enables Beaker to provision VMs using KubeVirt for automated acceptance testing of Puppet code.'
  spec.homepage = 'https://github.com/voxpupuli/beaker-kubevirt'
  spec.license = 'AGPL-3.0-or-later'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'base64', '~> 0.1'
  spec.add_dependency 'bcrypt_pbkdf', '~> 1.0'
  spec.add_dependency 'beaker', '~> 7.0', '>= 7.0.0'
  spec.add_dependency 'eventmachine', '~> 1.2'
  spec.add_dependency 'faye-websocket', '~> 0.12'
  spec.add_dependency 'kubeclient', '>= 4.9.3', '< 5.0.0'
  spec.add_dependency 'pstore', '~> 0.1'
  spec.add_development_dependency 'voxpupuli-rubocop', '~> 5.3.0'
end
