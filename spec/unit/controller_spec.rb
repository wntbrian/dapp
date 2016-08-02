require_relative '../spec_helper'

describe Dapp::Controller do
  include SpecHelper::Common
  include SpecHelper::Expect

  RSpec.configure do |c|
    c.before(:example, :build) { stub_application(:build!) }
    c.before(:example, :push) { stub_application(:export!) }
  end

  def stub_application(method)
    stub_instance(Dapp::Application) do |instance|
      allow(instance).to receive(method)
    end
  end

  def stubbed_controller(cli_options: {}, patterns: nil)
    allow_any_instance_of(Dapp::Controller).to receive(:build_configs) {
      [RecursiveOpenStruct.new(_name: 'project'),
       RecursiveOpenStruct.new(_name: 'project2')]
    }
    controller(cli_options: cli_options, patterns: patterns)
  end

  def controller(cli_options: {}, patterns: nil)
    @controller ||= Dapp::Controller.new(cli_options: { log_color: 'auto' }.merge(cli_options), patterns: patterns)
  end

  it 'build', :build, test_construct: true do
    Pathname('Dappfile').write("docker.from 'ubuntu.16.04'")
    expect { controller.build }.to_not raise_error
  end

  it 'build:docker_from_not_defined', test_construct: true do
    FileUtils.touch('Dappfile')
    expect_exception_code(code: :docker_from_not_defined) { controller.build }
  end

  it 'push:push_command_unexpected_apps_number', :push do
    expect_exception_code(code: :push_command_unexpected_apps_number) { stubbed_controller.push('name') }
  end

  it 'run:run_command_unexpected_apps_number', :push do
    expect_exception_code(code: :run_command_unexpected_apps_number) { stubbed_controller.run([], []) }
  end

  it 'list' do
    expect { stubbed_controller.list }.to_not raise_error
  end

  it 'paint_initialize expected cli_options[:log_color] (RuntimeError)' do
    expect { Dapp::Controller.new }.to raise_error RuntimeError
  end

  context 'build_confs' do
    before :each do
      FileUtils.mkdir_p('.dapps/project/config/en')
      FileUtils.touch('.dapps/project/Dappfile')
    end

    it '.', test_construct: true do
      expect { controller(cli_options: { dir: '.dapps/project/' }).send(:build_configs) }.to_not raise_error
    end

    it '.dapps', test_construct: true do
      expect { controller.send(:build_configs) }.to_not raise_error
    end

    it 'search up', test_construct: true do
      expect { controller(cli_options: { dir: '.dapps/project/config/en' }).send(:build_configs) }.to_not raise_error
    end

    it 'dappfile_not_found', test_construct: true do
      expect_exception_code(code: :dappfile_not_found) { controller(cli_options: { dir: '.dapps' }).send(:build_configs) }
    end

    it 'no_such_app', test_construct: true do
      expect_exception_code(code: :no_such_app) { controller(patterns: ['app*']).send(:build_configs) }
    end
  end
end