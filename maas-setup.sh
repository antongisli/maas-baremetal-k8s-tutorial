#get local interface name (this assumes a single default route is present)
export INTERFACE=$(ip route | grep default | cut -d ' ' -f 5)
export IP_ADDRESS=$(ip -4 addr show dev $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p
iptables -t nat -A POSTROUTING -o $INTERFACE -j SNAT --to $IP_ADDRESS
#TODO inbound port forwarding/load balancing
# Persist NAT configuration
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
apt-get install iptables-persistent -y
# LXD init
cat /tmp/lxd.cfg | lxd init --preseed
# Wait for LXD to be ready
lxd waitready
# Initialise MAAS
maas init region+rack --database-uri maas-test-db:/// --maas-url http://${IP_ADDRESS}:5240/MAAS
sleep 15
# Create MAAS admin and grab API key
maas createadmin --username admin --password admin --email admin
export APIKEY=$(maas apikey --username admin)
# MAAS admin login
maas login admin 'http://localhost:5240/MAAS/' $APIKEY
# Configure MAAS networking (set gateways, vlans, DHCP on etc)
export SUBNET=10.10.10.0/24
export FABRIC_ID=$(maas admin subnet read "$SUBNET" | jq -r ".vlan.fabric_id")
export VLAN_TAG=$(maas admin subnet read "$SUBNET" | jq -r ".vlan.vid")
export PRIMARY_RACK=$(maas admin rack-controllers read | jq -r ".[] | .system_id")
maas admin subnet update $SUBNET gateway_ip=10.10.10.1
maas admin ipranges create type=dynamic start_ip=10.10.10.200 end_ip=10.10.10.254
maas admin vlan update $FABRIC_ID $VLAN_TAG dhcp_on=True primary_rack=$PRIMARY_RACK
maas admin maas set-config name=upstream_dns value=8.8.8.8
# Add LXD as a VM host for MAAS
maas admin vm-hosts create  password=password  type=lxd power_address=https://${IP_ADDRESS}:8443 project=maas

#creating VMs
#TODO find out the name of our vm host, and store this id in a variable
maas admin vm-hosts read | jq '.[] | select (.name=="proud-possum") | .name, .id'
# add a VM
#TODO use the variable for the VM host ID (below it is static 1)
maas admin vm-host compose 1 cores=4 cpu_speed=300 memory=8192 architecture="amd64/generic" \
 storage="main:100(pool1)"

 # Juju (note, this section requires manual intervention)
sudo snap install juju --classic
sed -i 's/IP_ADDRESS/${IP_ADDRESS}/' maas-cloud.yaml
juju add-cloud --local maas-cloud maas-cloud.yaml
juju add-credential maas-cloud
juju clouds --local
juju credentials
juju bootstrap maas-cloud