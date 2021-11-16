# lxd / maas issue. either upgrade lxd or maas to 3.1
sudo snap switch --channel=4.19/stable lxd
sudo snap refresh lxd
sudo snap install jq
sudo snap install --channel=3.1/beta maas
sudo snap install --channel=3.1/beta maas-test-db

# clone the git repository
cd ~
git clone https://github.com/antongisli/maas-baremetal-k8s-tutorial.git

# get local interface name (this assumes a single default route is present)
export INTERFACE=$(ip route | grep default | cut -d ' ' -f 5)
export IP_ADDRESS=$(ip -4 addr show dev $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p
sudo iptables -t nat -A POSTROUTING -o $INTERFACE -j SNAT --to $IP_ADDRESS
#TODO inbound port forwarding/load balancing
# Persist NAT configuration
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo apt-get install iptables-persistent -y
# LXD init
sudo cat maas-baremetal-k8s-tutorial/lxd.conf | lxd init --preseed
# verify LXD network config
lxc network show lxdbr0
# Wait for LXD to be ready
lxd waitready
# Initialise MAAS
sudo maas init region+rack --database-uri maas-test-db:/// --maas-url http://${IP_ADDRESS}:5240/MAAS
sleep 15
# Create MAAS admin and grab API key
sudo maas createadmin --username admin --password admin --email admin
export APIKEY=$(sudo maas apikey --username admin)
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
# Add LXD as a VM host for MAAS and capture the VM_HOST_ID
VM_HOST_ID=$(maas admin vm-hosts create  password=password  type=lxd power_address=https://${IP_ADDRESS}:8443 \
 project=maas | jq '.id')

### creating VMs for Juju controller and our "bare metal"

# add a VM for the juju controller with minimal memory
maas admin vm-host compose $VM_HOST_ID cores=8 memory=2048 architecture="amd64/generic" \
 storage="main:16(pool1)" hostname="juju-controller"
# get the system-id and tag the machine with "juju-controller"
JUJU_SYSID=$(maas admin machines read | jq  '.[] 
| select(."hostname"=="juju-controller") 
| .["system_id"]' | tr -d '"')
maas admin tag update-nodes "juju-controller" add=$JUJU_SYSID

## Create 3 "bare metal" machines and tag them with "metal"
for ID in 1 2 3
do
    maas admin vm-host compose $VM_HOST_ID cores=8 memory=8192 architecture="amd64/generic" \
     storage="main:25(pool1),ceph:150(pool1)" hostname="metal-${ID}"
	SYSID=$(maas admin machines read | jq -r --arg MACHINE "metal-${ID}" '.[] 
    | select(."hostname"==$MACHINE) 
    | .["system_id"]' | tr -d '"')
    maas admin tag update-nodes "metal" add=$SYSID
done


### Juju setup (note, this section requires manual intervention)
cd ~
sudo snap install juju --classic
sed -i 's/IP_ADDRESS/${IP_ADDRESS}/' maas-cloud.yaml
juju add-cloud --local maas-cloud maas-cloud.yaml
juju add-credential maas-cloud
juju clouds --local
juju credentials
# Bootstrap the maas-cloud - get a coffee
juju bootstrap maas-cloud --bootstrap-constraints "tags=juju-controller mem=2G"

# fire up the juju gui to view the fun
juju gui
# get coffee

### Ceph
juju deploy -n 3 ceph-mon --to lxd:0,lxd:1,lxd:2
juju deploy --config ceph-osd.yaml cs:ceph-osd -n 3 --to 0,1,2
juju add-relation ceph-mon ceph-osd

# watch the fun (with a another coffee). 
watch -c juju status --color
# Wait for Ceph to settle before proceeding

### Kubernetes

# Deploy kubernetes-core with juju and re-use existing machines. 
juju deploy kubernetes-core --map-machines=existing,0=0,1=1

# add the new kubernetes as a cloud to juju
mkdir ~/.kube
juju scp kubernetes-master/1:/home/ubuntu/config ~/.kube/config

# add storage relations
juju add-relation ceph-mon:admin kubernetes-master
juju add-relation ceph-mon:client kubernetes-master

# add k8s to juju (choose option 1, client only)
juju add-k8s my-k8s

juju bootstrap my-k8s



### Deploying applications
# juju add-model some-model my-k8s
# juju deploy someapp(s)

### Cleanup? not sure this always works.

#juju destroy-controller -y --destroy-all-models --destroy-storage maas-cloud-default

### Notes / LMA stack deployment
## add an LMA model to the cluster
juju add-model lma my-k8s

juju deploy lma-light --channel=edge --trust

## random notes
# get some storage going
# https://jaas.ai/ceph-base
# https://jaas.ai/canonical-kubernetes/bundle/471
