case node['platform_family']
when 'debian'
  include_recipe 'apt'
when 'rhel'
  include_recipe 'yum'
end

include_recipe 'lvm::default'

if node['cloud'] && node['cloud']['provider'] == 'ec2' && node['cloud']['backend_storage_type'] == 'ebs'
  include_recipe 'aws'

  private_chef_backend_storage 'ebs_shared_storage' do
    action :ebs_shared
    only_if { node['private-chef']['backends'][node.name] }
    not_if { ::File.exists?('/var/opt/opscode/drbd/drbd_ready') }
  end

  template '/var/opt/opscode/keepalived/bin/custom_backend_storage' do
    source 'custom_backend_storage.ebs.erb'
    owner 'root'
    group 'root'
    mode '0700'
  end
else
  private_chef_backend_storage 'drbd_el_traditicional' do
    action :drbd
  end
end