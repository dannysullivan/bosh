require 'spec_helper'

module Bosh::Director
  describe DeploymentPlan::Steps::PackageCompileStep do
    include Support::StemcellHelpers

    let(:job) { double('job').as_null_object }
    let(:cloud) { double(:cpi) }
    let(:vm_deleter) { VmDeleter.new(cloud, Config.logger) }
    let(:vm_creator) { VmCreator.new(cloud, Config.logger, vm_deleter) }
    let(:release_version_model) { Models::ReleaseVersion.make }
    let(:config) { instance_double('Bosh::Director::DeploymentPlan::CompilationConfig') }
    let(:deployment) { Models::Deployment.make(name: 'mycloud') }
    let(:plan) { instance_double('Bosh::Director::DeploymentPlan::Planner', compilation: config, model: deployment, name: 'mycloud') }
    let(:instance_reuser) { InstanceReuser.new }
    let(:compilation_instance_pool) { DeploymentPlan::CompilationInstancePool.new(instance_reuser, vm_creator, vm_deleter, plan, logger) }
    let(:thread_pool) do
      thread_pool = instance_double('Bosh::Director::ThreadPool')
      allow(thread_pool).to receive(:wrap).and_yield(thread_pool)
      allow(thread_pool).to receive(:process).and_yield
      allow(thread_pool).to receive(:working?).and_return(false)
      thread_pool
    end

    before do
      allow(ThreadPool).to receive_messages(new: thread_pool) # Using threads for real, even accidentally makes debugging a nightmare

      allow(Config).to receive_messages(redis: double('fake-redis'))

      allow(Config).to receive(:cloud).and_return(cloud)

      @blobstore = double(:blobstore)
      allow(Config).to receive(:blobstore).and_return(@blobstore)

      @director_job = instance_double('Bosh::Director::Jobs::BaseJob')
      allow(Config).to receive(:current_job).and_return(@director_job)
      allow(@director_job).to receive(:task_cancelled?).and_return(false)

      @network = instance_double('Bosh::Director::DeploymentPlan::Network', name: 'default', reserve: nil)
      allow(plan).to receive(:network).with('default').and_return(@network)

      @n_workers = 3
      allow(config).to receive_messages(
          network_name: 'default',
          env: {},
          cloud_properties: {},
          workers: @n_workers,
          reuse_compilation_vms: false)

      allow(Config).to receive(:use_compiled_package_cache?).and_return(false)
      @all_packages = []
    end

    def make_package(name, deps = [], version = '0.1-dev')
      package = Models::Package.make(name: name, version: version)
      package.dependency_set = deps
      package.save
      @all_packages << package
      package
    end

    def make_compiled(release_version_model, package, stemcell, sha1 = 'deadbeef', blobstore_id = 'deadcafe')
      transitive_dependencies = release_version_model.transitive_dependencies(package)
      package_dependency_key = Models::CompiledPackage.create_dependency_key(transitive_dependencies)
      package_cache_key = Models::CompiledPackage.create_cache_key(package, transitive_dependencies, stemcell)

      CompileTask.new(package, stemcell, job, package_dependency_key, package_cache_key)

      Models::CompiledPackage.make(package: package,
        dependency_key: package_dependency_key,
        stemcell: stemcell,
        build: 1,
        sha1: sha1,
        blobstore_id: blobstore_id)
    end

    def prepare_samples
      @release = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion', name: 'cf-release', model: release_version_model)
      @stemcell_a = make_stemcell
      @stemcell_b = make_stemcell

      @p_common = make_package('common')
      @p_syslog = make_package('p_syslog')
      @p_dea = make_package('dea', %w(ruby common))
      @p_ruby = make_package('ruby', %w(common))
      @p_warden = make_package('warden', %w(common))
      @p_nginx = make_package('nginx', %w(common))
      @p_router = make_package('p_router', %w(ruby common))

      rp_large = double('Bosh::Director::DeploymentPlan::ResourcePool', name: 'large', stemcell: @stemcell_a)

      rp_small = instance_double('Bosh::Director::DeploymentPlan::ResourcePool', name: 'small', stemcell: @stemcell_b)

      @t_dea = instance_double('Bosh::Director::DeploymentPlan::Template', release: @release, package_models: [@p_dea, @p_nginx, @p_syslog], name: 'dea')

      @t_warden = instance_double('Bosh::Director::DeploymentPlan::Template', release: @release, package_models: [@p_warden], name: 'warden')

      @t_nginx = instance_double('Bosh::Director::DeploymentPlan::Template', release: @release, package_models: [@p_nginx], name: 'nginx')

      @t_router = instance_double('Bosh::Director::DeploymentPlan::Template', release: @release, package_models: [@p_router], name: 'router')

      @j_dea = instance_double('Bosh::Director::DeploymentPlan::Job',
        name: 'dea',
        release: @release,
        templates: [@t_dea, @t_warden],
        resource_pool: rp_large)
      @j_router = instance_double('Bosh::Director::DeploymentPlan::Job',
        name: 'router',
        release: @release,
        templates: [@t_nginx, @t_router, @t_warden],
        resource_pool: rp_small)

      @package_set_a = [@p_dea, @p_nginx, @p_syslog, @p_warden, @p_common, @p_ruby]

      @package_set_b = [@p_nginx, @p_common, @p_router, @p_warden, @p_ruby]

      (@package_set_a + @package_set_b).each do |package|
        release_version_model.packages << package
      end
    end

    context 'when all needed packages are compiled' do
      it "doesn't perform any compilation" do
        prepare_samples

        allow(plan).to receive(:jobs).and_return([@j_dea, @j_router])

        @package_set_a.each do |package|
          cp1 = make_compiled(release_version_model, package, @stemcell_a.model)
          expect(@j_dea).to receive(:use_compiled_package).with(cp1)
        end

        @package_set_b.each do |package|
          cp2 = make_compiled(release_version_model, package, @stemcell_b.model)
          expect(@j_router).to receive(:use_compiled_package).with(cp2)
        end

        compiler = DeploymentPlan::Steps::PackageCompileStep.new(plan, compilation_instance_pool,
          logger, Config.event_log, nil)

        compiler.perform
        # For @stemcell_a we need to compile:
        # [p_dea, p_nginx, p_syslog, p_warden, p_common, p_ruby] = 6
        # For @stemcell_b:
        # [p_nginx, p_common, p_router, p_ruby, p_warden] = 5
        expect(compiler.compile_tasks_count).to eq(6 + 5)
        # But they are already compiled!
        expect(compiler.compilations_performed).to eq(0)

        expect(log_string).to include("Job templates `cf-release/dea', `cf-release/warden' need to run on stemcell `#{@stemcell_a.model.desc}'")
        expect(log_string).to include("Job templates `cf-release/nginx', `cf-release/router', `cf-release/warden' need to run on stemcell `#{@stemcell_b.model.desc}'")
      end
    end

    def make_instances(num)
      (0..num-1).map do
        vm = instance_double('Bosh::Director::DeploymentPlan::Instance', model: Models::Vm.make)
        instance = instance_double('Bosh::Director::DeploymentPlan::Instance', vm: vm)
        expect(instance).to receive(:bind_unallocated_vm)
        expect(instance).to receive(:reserve_networks)
        expect(instance).to receive(:add_network_reservation).with(instance_of(Bosh::Director::DynamicNetworkReservation))
        expect(instance).to receive(:delete)

        instance
      end
    end

    context 'when none of the packages are compiled' do
      it 'compiles all packages' do
        prepare_samples

        allow(plan).to receive(:jobs).and_return([@j_dea, @j_router])

        compiler = DeploymentPlan::Steps::PackageCompileStep.new(plan, compilation_instance_pool, logger, Config.event_log, @director_job)

        expect(vm_creator).to receive(:create_for_instance).exactly(11).times
        instances = make_instances(11)
        expect(Bosh::Director::DeploymentPlan::Instance).to receive(:new).exactly(11).times.and_return(*instances)

        vm_metadata_updater = instance_double('Bosh::Director::VmMetadataUpdater', update: nil)
        allow(Bosh::Director::VmMetadataUpdater).to receive_messages(build: vm_metadata_updater)
        expect(vm_metadata_updater).to receive(:update).with(anything, {compiling: 'common'})
        expect(vm_metadata_updater).to receive(:update).with(anything, hash_including(:compiling)).exactly(10).times

        instances.each do |instance|
          agent_client = instance_double('Bosh::Director::AgentClient')
          expect(instance).to receive(:agent_client).and_return(agent_client)

          expect(agent_client).to receive(:compile_package) do |*args|
            name = args[2]
            dot = args[3].rindex('.')
            version, build = args[3][0..dot-1], args[3][dot+1..-1]

            package = Models::Package.find(name: name, version: version)
            expect(args[0]).to eq(package.blobstore_id)
            expect(args[1]).to eq(package.sha1)

            expect(args[4]).to be_a(Hash)

            {
              'result' => {
                'sha1' => "compiled #{package.id}",
                'blobstore_id' => "blob #{package.id}"
              }
            }
          end
        end

        @package_set_a.each do |package|
          expect(compiler).to receive(:with_compile_lock).with(package.id, @stemcell_a.model.id).and_yield
        end

        @package_set_b.each do |package|
          expect(compiler).to receive(:with_compile_lock).with(package.id, @stemcell_b.model.id).and_yield
        end

        expect(@j_dea).to receive(:use_compiled_package).exactly(6).times
        expect(@j_router).to receive(:use_compiled_package).exactly(5).times

        expect(vm_deleter).to receive(:delete_for_instance).exactly(11).times

        expect(@director_job).to receive(:task_checkpoint).once

        compiler.perform
        expect(compiler.compilations_performed).to eq(11)

        @package_set_a.each do |package|
          expect(package.compiled_packages.size).to be >= 1
        end

        @package_set_b.each do |package|
          expect(package.compiled_packages.size).to be >= 1
        end
      end
    end

    context 'when the deploy is cancelled and there is a pending compilation' do
      # this can happen when the cancellation comes in when there is a package to be compiled,
      # and the compilation is not even in-flight. e.g.
      # - you have 3 compilation workers, but you've got 5 packages to compile; or
      # - package "bar" depends on "foo", deploy is cancelled when compiling "foo" ("bar" is blocked)

      it 'cancels the compilation' do
        director_job = instance_double('Bosh::Director::Jobs::BaseJob', task_checkpoint: nil, task_cancelled?: true)
        event_log = instance_double('Bosh::Director::EventLog::Log', begin_stage: nil)
        allow(event_log).to receive(:track).with(anything).and_yield

        config = class_double('Bosh::Director::Config').as_stubbed_const
        allow(config).to receive_messages(
          current_job: director_job,
          cloud: double('cpi'),
          event_log: event_log,
          logger: logger,
          use_compiled_package_cache?: false,
        )

        network = double('network', name: 'network_name')
        compilation_config = instance_double('Bosh::Director::DeploymentPlan::CompilationConfig', cloud_properties: {}, env: {}, workers: 1, reuse_compilation_vms: true, network_name: 'network_name')
        release_version_model = instance_double('Bosh::Director::Models::ReleaseVersion', dependencies: Set.new, transitive_dependencies: Set.new)
        release_version = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion', name: 'release_name', model: release_version_model)
        stemcell = make_stemcell
        resource_pool = double('resource_pool', stemcell: stemcell)
        job = instance_double('Bosh::Director::DeploymentPlan::Job', release: release_version, name: 'job_name', resource_pool: resource_pool)
        package_model = instance_double('Bosh::Director::Models::Package', name: 'foobarbaz', desc: 'package description', id: 'package_id', dependency_set: [],
          fingerprint: 'deadbeef')
        template = instance_double('Bosh::Director::DeploymentPlan::Template', release: release_version, package_models: [package_model], name: 'fake_template')
        allow(job).to receive_messages(templates: [template])
        planner = instance_double('Bosh::Director::DeploymentPlan::Planner', compilation: compilation_config, name: 'mycloud')

        allow(planner).to receive(:network).with('network_name') { network }
        allow(planner).to receive(:jobs).and_return([job])

        compiler = DeploymentPlan::Steps::PackageCompileStep.new(planner, compilation_instance_pool, logger, event_log, director_job)

        expect {
          compiler.perform
        }.not_to raise_error
      end
    end

    describe 'with reuse_compilation_vms option set' do
      let(:net) { {'default' => 'network settings'} }
      let(:initial_state) {
        {
          'deployment' => 'mycloud',
          'job' => {
            'name' => 'compilation-deadbeef'
          },
          'index' => 0,
          'id' => 'deadbeef',
          'availability_zone' => nil,
          'networks' => {'default' => 'network settings'},
          'resource_pool' => {},
          'packages' => {},
          'configuration_hash' => nil,
          'properties' => {},
          'dns_domain_name' => nil,
          'links' => {},
          'persistent_disk' => 0,
          'bootstrap' => true
        }
      }
      before { allow(SecureRandom).to receive(:uuid).and_return('deadbeef') }

      it 'reuses compilation VMs' do
        prepare_samples
        allow(plan).to receive(:jobs).and_return([@j_dea])

        allow(config).to receive_messages(reuse_compilation_vms: true)

        instances = make_instances(1)
        expect(vm_creator).to receive(:create_for_instance).exactly(1).times
        expect(Bosh::Director::DeploymentPlan::Instance).to receive(:new).exactly(1).times.and_return(*instances)

        instances.each do |instance|
          agent_client = instance_double('Bosh::Director::AgentClient')
          expect(instance).to receive(:agent_client).and_return(agent_client).exactly(6).times
          expect(agent_client).to receive(:compile_package).at_most(6).times do |*args|
            name = args[2]
            dot = args[3].rindex('.')
            version, build = args[3][0..dot-1], args[3][dot+1..-1]

            package = Models::Package.find(name: name, version: version)
            expect(args[0]).to eq(package.blobstore_id)
            expect(args[1]).to eq(package.sha1)

            expect(args[4]).to be_a(Hash)

            {
              'result' => {
                'sha1' => "compiled #{package.id}",
                'blobstore_id' => "blob #{package.id}"
              }
            }
          end
        end

        expect(@j_dea).to receive(:use_compiled_package).exactly(6).times

        expect(vm_deleter).to receive(:delete_for_instance).exactly(1).times

        expect(@director_job).to receive(:task_checkpoint).once

        compiler = DeploymentPlan::Steps::PackageCompileStep.new(plan, compilation_instance_pool, logger, Config.event_log, @director_job)

        @package_set_a.each do |package|
          expect(compiler).to receive(:with_compile_lock).with(package.id, @stemcell_a.model.id).and_yield
        end

        compiler.perform
        expect(compiler.compilations_performed).to eq(6)

        @package_set_a.each do |package|
          expect(package.compiled_packages.size).to be >= 1
        end
      end

      it 'cleans up compilation vms if there is a failing compilation' do
        prepare_samples
        allow(plan).to receive(:jobs).and_return([@j_dea])

        allow(config).to receive_messages(reuse_compilation_vms: true)
        allow(config).to receive_messages(workers: 1)
        allow(@network).to receive(:network_settings).and_return('network settings')
        expect(@network).to receive(:reserve) { |reservation| reservation.mark_reserved_as(DynamicNetworkReservation) }

        vm_cid = 'vm-cid-1'
        agent = instance_double('Bosh::Director::AgentClient')

        expect(cloud).to receive(:create_vm).
          with(instance_of(String), @stemcell_a.model.cid, {}, net, [], {}).
          and_return(vm_cid)

        allow(AgentClient).to receive(:with_vm).and_return(agent)

        expect(agent).to receive(:wait_until_ready)
        expect(agent).to receive(:update_settings)
        expect(agent).to receive(:get_state)
        expect(agent).to receive(:apply).with(initial_state)
        expect(agent).to receive(:compile_package).and_raise(RuntimeError)

        expect(cloud).to receive(:delete_vm).with(vm_cid)

        expect(@network).to receive(:release)

        compiler = DeploymentPlan::Steps::PackageCompileStep.new(plan, compilation_instance_pool, logger, Config.event_log, @director_job)
        allow(compiler).to receive(:with_compile_lock).and_yield

        expect {
          compiler.perform
        }.to raise_error(RuntimeError)
      end
    end

    describe 'tearing down compilation vms' do
      before do # prepare compilation
        prepare_samples

        release = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion', model: release_version_model, name: 'release')
        stemcell = make_stemcell
        resource_pool = instance_double('Bosh::Director::DeploymentPlan::ResourcePool', stemcell: stemcell)

        package = make_package('common')
        template = instance_double('Bosh::Director::DeploymentPlan::Template', release: release, package_models: [package], name: 'fake_template')
        job = instance_double(
          'Bosh::Director::DeploymentPlan::Job',
          name: 'job-with-one-package',
          release: release,
          templates: [template],
          resource_pool: resource_pool,
        )

        allow(plan).to receive_messages(jobs: [job])
      end

      before do # create vm
        allow(@network).to receive(:reserve)
        allow(@network).to receive(:network_settings)
        allow(cloud).to receive(:create_vm).and_return('vm-cid-1')
      end

      def self.it_tears_down_vm_exactly_once
        it 'tears down VMs exactly once when RpcTimeout error occurs' do
          # agent raises error
          agent = instance_double('Bosh::Director::AgentClient')
          expect(agent).to receive(:wait_until_ready).and_raise(RpcTimeout)
          expect(AgentClient).to receive(:with_vm).and_return(agent)

          expect(cloud).to receive(:delete_vm).once
          allow(@network).to receive(:release)

          compiler = DeploymentPlan::Steps::PackageCompileStep.new(plan, compilation_instance_pool, logger, Config.event_log, @director_job)
          allow(compiler).to receive(:with_compile_lock).and_yield
          expect { compiler.perform }.to raise_error(RpcTimeout)
        end
      end

      context 'reuse_compilation_vms is true' do
        before { allow(config).to receive_messages(reuse_compilation_vms: true) }
        it_tears_down_vm_exactly_once
      end

      context 'reuse_compilation_vms is false' do
        before { allow(config).to receive_messages(reuse_compilation_vms: false) }
        it_tears_down_vm_exactly_once
      end
    end

    it 'should make sure a parallel deployment did not compile a package already' do
      package = Models::Package.make
      stemcell = make_stemcell

      task = CompileTask.new(package, stemcell, job, 'fake-dependency-key', 'fake-cache-key')

      compiler = DeploymentPlan::Steps::PackageCompileStep.new(plan, compilation_instance_pool, logger, Config.event_log, nil)
      fake_compiled_package = instance_double('Bosh::Director::Models::CompiledPackage', name: 'fake')
      allow(task).to receive(:find_compiled_package).and_return(fake_compiled_package)

      allow(compiler).to receive(:with_compile_lock).with(package.id, stemcell.model.id).and_yield
      compiler.compile_package(task)

      expect(task.compiled_package).to eq(fake_compiled_package)
    end

    describe 'the global blobstore' do
      let(:package) { Models::Package.make }
      let(:stemcell) { make_stemcell }
      let(:task) { CompileTask.new(package, stemcell, job, 'fake-dependency-key', 'fake-cache-key') }
      let(:compiler) { DeploymentPlan::Steps::PackageCompileStep.new(plan, compilation_instance_pool, logger, Config.event_log, nil) }
      let(:cache_key) { 'cache key' }

      before do
        allow(task).to receive(:cache_key).and_return(cache_key)

        allow(Config).to receive(:use_compiled_package_cache?).and_return(true)
      end

      it 'should check if compiled package is in global blobstore' do
        allow(compiler).to receive(:with_compile_lock).with(package.id, stemcell.model.id).and_yield

        expect(BlobUtil).to receive(:exists_in_global_cache?).with(package, cache_key).and_return(true)
        allow(task).to receive(:find_compiled_package)
        expect(BlobUtil).not_to receive(:save_to_global_cache)
        allow(compiler).to receive(:prepare_vm)
        compiled_package = instance_double('Bosh::Director::Models::CompiledPackage', name: 'fake')
        allow(Models::CompiledPackage).to receive(:create).and_return(compiled_package)

        compiler.compile_package(task)
      end

      it 'should save compiled package to global cache if not exists' do
        expect(compiler).to receive(:with_compile_lock).with(package.id, stemcell.model.id).and_yield

        allow(task).to receive(:find_compiled_package)
        compiled_package = instance_double(
          'Bosh::Director::Models::CompiledPackage',
          name: 'fake-package-name', package: package,
          stemcell: stemcell, blobstore_id: 'some blobstore id')
        expect(BlobUtil).to receive(:exists_in_global_cache?).with(package, cache_key).and_return(false)
        expect(BlobUtil).to receive(:save_to_global_cache).with(compiled_package, cache_key)
        allow(compiler).to receive(:prepare_vm)
        allow(Models::CompiledPackage).to receive(:create).and_return(compiled_package)

        compiler.compile_package(task)
      end

      it 'only checks the global cache if Config.use_compiled_package_cache? is set' do
        allow(Config).to receive(:use_compiled_package_cache?).and_return(false)

        allow(compiler).to receive(:with_compile_lock).with(package.id, stemcell.model.id).and_yield

        expect(BlobUtil).not_to receive(:exists_in_global_cache?)
        expect(BlobUtil).not_to receive(:save_to_global_cache)
        allow(compiler).to receive(:prepare_vm)
        compiled_package = instance_double('Bosh::Director::Models::CompiledPackage', name: 'fake')
        allow(Models::CompiledPackage).to receive(:create).and_return(compiled_package)

        compiler.compile_package(task)
      end
    end

    describe '#prepare_vm' do
      let(:network) { double('network', name: 'default', network_settings: nil) }
      let(:compilation) do
        config = double('compilation_config')
        allow(config).to receive_messages(network_name: 'default')
        allow(config).to receive_messages(cloud_properties: double('cloud_properties'))
        allow(config).to receive_messages(env: double('env'))
        allow(config).to receive_messages(workers: 2)
        config
      end
      let(:plan) do
        double('Bosh::Director::DeploymentPlan',
          compilation: compilation,
          model: Models::Deployment.make,
          name: 'fake-deployment'
        )
      end
      let(:stemcell) { instance_double(DeploymentPlan::Stemcell, model: Models::Stemcell.make) }
      let(:vm) { Models::Vm.make }
      let(:instance) { instance_double(DeploymentPlan::Instance, vm: vm) }

      context 'with reuse_compilation_vms' do
        let(:instance_reuser) { instance_double('Bosh::Director::InstanceReuser') }

        before do
          allow(compilation).to receive_messages(reuse_compilation_vms: true)
          allow(vm_creator).to receive_messages(create: vm)
          allow(plan).to receive(:network).with('default').and_return(network)
        end

        it 'should clean up the compilation vm if it failed' do
          compiler = described_class.new(plan, compilation_instance_pool, logger, Config.event_log, @director_job)

          allow(vm_creator).to receive(:create_for_instance).and_raise(RpcTimeout)

          allow(instance_reuser).to receive_messages(get_instance: nil)
          allow(instance_reuser).to receive_messages(get_num_instances: 0)
          allow(instance_reuser).to receive_messages(add_in_use_instance: instance)
          allow(network).to receive(:reserve).with(instance_of(Bosh::Director::DynamicNetworkReservation))

          expect(instance_reuser).to receive(:remove_instance).ordered
          expect(vm_deleter).to receive(:delete_for_instance).ordered
          allow(network).to receive(:release)

          expect {
            compiler.prepare_vm(stemcell) do
              # nothing
            end
          }.to raise_error RpcTimeout
        end
      end
    end
  end
end
