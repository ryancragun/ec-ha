# encoding: utf-8

require 'chef_metal'
require 'chef/server_api'

def whyrun_supported?
  true
end

use_inline_resources

def cloud_machine_created?(vmname)
  rest = Chef::ServerAPI.new()
  begin
    nodeinfo = rest.get("/nodes/#{vmname}")
  rescue Net::HTTPServerException
    # Handle the 404 meaning the machine hasn't been created yet
    nodeinfo = {'normal' => {} }
  end
  provisioner_output = nodeinfo['normal']['provisioner_output']
  return true if provisioner_output && provisioner_output.has_key?('server_id')
  false
end

action :cloud_create do
 # Dumb hack to populate all of our machines first, for dynamic name/IP provisioners
  if node['harness']['provider'] == 'ec2'
    %w(backends frontends).each do |whichend|
      node['harness']['vm_config'][whichend].each do |vmname, config|
        ChefMetal.with_provisioner_options node['harness']['provisioner_options'][vmname]

        machine vmname do
          attribute 'private-chef', privatechef_attributes
          attribute 'root_ssh', node['harness']['root_ssh'].to_hash
          attribute 'cloud', cloud_attributes('ec2')
          recipe 'private-chef::hostname'
          recipe 'private-chef::ec2'

          not_if { cloud_machine_created?(vmname) }
        end
      end
    end
  end
end

action :install do
  %w(backends frontends).each do |whichend|
    node['harness']['vm_config'][whichend].each do |vmname, config|
      # provisoner_options is set by your provisioner recipe (ex: vagrant.rb)
      ChefMetal.with_provisioner_options node['harness']['provisioner_options'][vmname]

      machine vmname do
        attribute 'private-chef', privatechef_attributes
        attribute 'root_ssh', node['harness']['root_ssh'].to_hash

        recipe 'private-chef::hostsfile'
        recipe 'private-chef::provision'
        recipe 'private-chef::bugfixes'
        recipe 'private-chef::drbd' if node['harness']['vm_config']['backends'].include?(vmname)
        recipe 'private-chef::provision_phase2'
        recipe 'private-chef::users' if vmname == bootstrap_node_name
        recipe 'private-chef::reporting' if node['harness']['reporting_package']
        recipe 'private-chef::manage' if node['harness']['manage_package'] &&
          node['harness']['vm_config']['frontends'].include?(vmname)
        recipe 'private-chef::pushy' if node['harness']['pushy_package']

        converge true
      end
    end
  end

end

action :stop_all_but_master do
  # all backends minus bootstrap
  node['harness']['vm_config']['backends'].
    select { |vmname, config| config['bootstrap'] != true }.merge(
    node['harness']['vm_config']['frontends']).each do |vmname, config|

    ChefMetal.with_provisioner_options node['harness']['provisioner_options'][vmname]
    machine_execute "p-c-c_stop_on_#{vmname}" do
      command '/opt/opscode/bin/private-chef-ctl stop ; exit 0'
      machine vmname
    end

  end
end

action :destroy do

  # Bring the backends and frontends online
  node['harness']['vm_config']['backends'].merge(
    node['harness']['vm_config']['frontends']).each do |vmname, config|

    machine vmname do
      action :delete
    end
  end

end

def bootstrap_node_name
  node['harness']['vm_config']['backends'].select { |node,attrs| attrs['bootstrap'] == true }.keys.first
end

def installer_path(ec_package)
  return nil unless ec_package
  return ec_package if ::URI.parse(ec_package).absolute?
  ::File.join(node['harness']['vm_mountpoint'], ec_package)
end

def privatechef_attributes
  packages = package_attributes
  attributes = node['harness']['vm_config'].to_hash
  attributes['installer_file'] = packages['ec']
  unless packages['manage'] == nil
    attributes['manage_installer_file'] = packages['manage']
    attributes['configuration'] = { 'opscode_webui' => { 'enable' => false } }
  end
  attributes['reporting_installer_file'] = packages['reporting']
  attributes['pushy_installer_file'] = packages['pushy']
  attributes
end

def cloud_attributes(provider)
  cloud_attrs = node['harness'][provider].to_hash
  cloud_attrs['provider'] = provider

  case provider
  when 'ec2'
    aws_credentials = ChefMetal::AWSCredentials.new
    aws_credentials.load_default
    cloud_attrs['aws_access_key_id'] ||= aws_credentials.default[:access_key_id]
    cloud_attrs['aws_secret_access_key'] ||= aws_credentials.default[:secret_access_key]
  end

  cloud_attrs
end

def package_attributes
  packages = {}

  if new_resource.ec_package
    packages['ec'] = installer_path(new_resource.ec_package)
  else
    packages['ec'] = installer_path(node['harness']['default_package'])
  end
  packages['manage'] = installer_path(node['harness']['manage_package'])
  packages['reporting'] = installer_path(node['harness']['reporting_package'])
  packages['pushy'] = installer_path(node['harness']['pushy_package'])

  packages
end
