#
# Cookbook Name:: bcpc
# Recipe:: networking
#
# Copyright 2015, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "bcpc::default"
include_recipe "bcpc::certs"

template "/etc/hosts" do
    source "hosts.erb"
    mode 00644
    variables( :servers => get_all_nodes )
end

template "/etc/ssh/sshd_config" do
    source "sshd_config.erb"
    mode 00644
    notifies :restart, "service[ssh]", :immediately
end

service "ssh" do
    action [ :enable, :start ]
end

service "cron" do
    action [ :enable, :start ]
end

# Core networking package
package "vlan"

# Useful system tools
package "fio"
package "bc"
package "htop"
package "sysstat"
package "iperf"

# Remove spurious logging failures from this package
package "powernap" do
    action :remove
end

bash "enable-ip-forwarding" do
    user "root"
    code <<-EOH
        echo "1" > /proc/sys/net/ipv4/ip_forward
        sed --in-place '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    EOH
    not_if "grep -e '^net.ipv4.ip_forward=1' /etc/sysctl.conf"
end

bash "enable-nonlocal-bind" do
    user "root"
    code <<-EOH
        echo "1" > /proc/sys/net/ipv4/ip_nonlocal_bind
        sed --in-place '/^net.ipv4.ip_nonlocal_bind/d' /etc/sysctl.conf
        echo 'net.ipv4.ip_nonlocal_bind=1' >> /etc/sysctl.conf
    EOH
    not_if "grep -e '^net.ipv4.ip_nonlocal_bind=1' /etc/sysctl.conf"
end

bash "set-tcp-keepalive-timeout" do
    user "root"
    code <<-EOH
        echo "1800" > /proc/sys/net/ipv4/tcp_keepalive_time
        sed --in-place '/^net.ipv4.tcp_keepalive_time/d' /etc/sysctl.conf
        echo 'net.ipv4.tcp_keepalive_time=1800' >> /etc/sysctl.conf
    EOH
    not_if "grep -e '^net.ipv4.tcp_keepalive_time=1800' /etc/sysctl.conf"
end

bash "enable-mellanox" do
    user "root"
    code <<-EOH
                if [ -z "`lsmod | grep mlx4_en`" ]; then
                   modprobe mlx4_en
                fi
                if [ -z "`grep mlx4_en /etc/modules`" ]; then
                   echo "mlx4_en" >> /etc/modules
                fi
    EOH
    only_if "lspci | grep Mellanox"
end

subnet = node[:bcpc][:management][:subnet]
# XXX change subnet to pod or cell!!!
if ["floating", "storage", "management"].select{|i| node[:bcpc][:networks][subnet][i].attribute?("slaves")}.any?
  bash "enable-bonding" do
    user "root"
    code <<-EOH
      modprobe bonding
      echo 'bonding' >> /etc/modules
    EOH
    not_if "grep -e '^bonding' /etc/modules"
  end
end

bash "enable-8021q" do
    user "root"
    code <<-EOH
        modprobe 8021q
        echo '8021q' >> /etc/modules
    EOH
    not_if "grep -e '^8021q' /etc/modules"
end

directory "/etc/network/interfaces.d" do
  owner "root"
  group "root"
  mode 00755
  action :create
end

bash "setup-interfaces-source" do
  user "root"
  code <<-EOH
    echo "source /etc/network/interfaces.d/*.cfg" >> /etc/network/interfaces
  EOH
  not_if 'grep "^source /etc/network/interfaces.d/\*.cfg" /etc/network/interfaces'
end

# set up the DNS resolvers
# we want the VIP which will be running powerdns to be first on the list
# but the first entry in our master list is also the only one in pdns,
# so make that the last entry to minimize double failures when upstream dies.
resolvers=node[:bcpc][:dns_servers].dup
if node[:bcpc][:management][:vip] and get_nodes_for("powerdns").length() > 0
  resolvers.push resolvers.shift
  resolvers.unshift node[:bcpc][:management][:vip]
end

bash "update resolvers" do
  code <<-EOH
  echo "#{(resolvers.map{|r| "nameserver #{r}"} + ["search #{node[:bcpc][:domain_name]}"]).join('\n')}" | resolvconf -a #{node[:bcpc][:networks][subnet][:management][:interface]}.inet
  EOH
end

ifaces = %w(management storage floating)
ifaces.each_index do |i|
  iface = ifaces[i]
  device_name = node[:bcpc][:networks][subnet][iface][:interface]
  next if iface != "management" and \
      node[:bcpc][:networks][subnet][:management][:interface] == device_name
  template "/etc/network/interfaces.d/#{device_name}.cfg" do
    source "network.iface.erb"
    owner "root"
    group "root"
    mode 00644
    variables(
      :interface => node[:bcpc][:networks][subnet][iface][:interface],
      :ip => node[:bcpc][iface][:ip],
      :netmask => node[:bcpc][:networks][subnet][iface][:netmask],
      :gateway => node[:bcpc][:networks][subnet][iface][:gateway],
      :slaves => node[:bcpc][:networks][subnet][iface].attribute?("slaves") ? node[:bcpc][:networks][subnet][iface]["slaves"] : false, 
      :dns => resolvers,
      :mtu => node[:bcpc][:networks][subnet][iface][:mtu],
      :metric => i*100
    )
  end
  
  bash "#{iface} up" do
    code <<-EOH
      ifup #{device_name} #{node[:bcpc][iface].attribute?("slaves") and node[:bcpc][iface][:slaves].join(" ")}
    EOH
    not_if "ip link show up | grep #{device_name}"
  end
end

bash "interface-mgmt-make-static-if-dhcp" do
  user "root"
  code <<-EOH
  sed --in-place '/\\(.*#{node[:bcpc][:networks][subnet][:management][:interface]}.*\\)/d' /etc/network/interfaces
  resolvconf -d #{node[:bcpc][:networks][subnet][:management][:interface]}.dhclient
  pkill -u root dhclient
  EOH
  only_if "cat /etc/network/interfaces | grep #{node[:bcpc][:networks][subnet][:management][:interface]} | grep dhcp"
end

if node[:bcpc][:networks][subnet][:management][:interface] != node[:bcpc][:networks][subnet][:storage][:interface]
  bash "routing-storage" do
      user "root"
      code "echo '2 storage' >> /etc/iproute2/rt_tables"
      not_if "grep -e '^2 storage' /etc/iproute2/rt_tables"
  end
end
  
if node[:bcpc][:networks][subnet][:management][:interface] != node[:bcpc][:networks][subnet][:storage][:interface] or \
   node[:bcpc][:networks][subnet][:management][:interface] != node[:bcpc][:networks][subnet][:floating][:interface]
  bash "routing-management" do
      user "root"
      code "echo '1 mgmt' >> /etc/iproute2/rt_tables"
      not_if "grep -e '^1 mgmt' /etc/iproute2/rt_tables"
  end
  
  template "/etc/network/if-up.d/bcpc-routing" do
      mode 00775
      source "bcpc-routing.erb"
      notifies :run, "execute[run-routing-script-once]", :immediately
  end
  
  execute "run-routing-script-once" do
      action :nothing
      command "/etc/network/if-up.d/bcpc-routing"
  end
end
  
bash "disable-noninteractive-pam-logging" do
    user "root"
    code "sed --in-place 's/^\\(session\\s*required\\s*pam_unix.so\\)/#\\1/' /etc/pam.d/common-session-noninteractive"
    only_if "grep -e '^session\\s*required\\s*pam_unix.so' /etc/pam.d/common-session-noninteractive"
end
