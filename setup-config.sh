#!/bin/bash -x

#
# Create networks
#
source ~/admin-openrc
openstack network create  --share --external \
  --provider-physical-network provider \
  --provider-network-type flat provider
openstack subnet create --network provider \
  --allocation-pool start=192.168.2.10,end=192.168.2.250 \
  --dns-nameserver 75.75.75.75 --gateway 192.168.1.1 \
  --subnet-range 192.168.0.0/22 provider

source ~/demo-openrc
openstack network create selfservice
openstack subnet create --network selfservice \
  --dns-nameserver 75.75.75.75 --gateway 172.16.1.1 \
  --subnet-range 172.16.1.0/24 selfservice
openstack router create router
neutron router-interface-add router selfservice
neutron router-gateway-set router provider

source ~/admin-openrc
ip netns
neutron router-port-list router

#
# Basic setup
#
./default-flavors.sh

ssh-keygen -q -N "" -f ~/.ssh/id_rsa_mykey
source ~/demo-openrc
openstack keypair create --public-key ~/.ssh/id_rsa_mykey.pub mykey
openstack keypair list
openstack network list
export NET_ID=$(openstack network list | awk '/ provider / { print $2 }')
openstack stack create -t demo-template.yml --parameter "NetID=$NET_ID" stack
sleep 1m
openstack stack list
openstack stack output show --all stack
openstack server list
