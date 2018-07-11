#!/bin/bash -x

if [ "$#" -ne 1 ]; then
    export IP_ADDR=$(hostname -i)
else
    export IP_ADDR=$1
fi

export DEBIAN_FRONTEND=noninteractive

source passwords.sh

apt -y install python3-openstackclient crudini

#
# MariaDB
#
apt -y install mariadb-server python3-pymysql

cat > /etc/mysql/mariadb.conf.d/99-openstack.cnf <<EOF
[mysqld]
bind-address = $IP_ADDR

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

service mysql restart

mysql -sfu root <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

#
# RabbitMQ
#
apt -y install rabbitmq-server
rabbitmqctl add_user openstack $RABBIT_PASS
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

#
# Memcached
#
apt -y install memcached python3-memcache
sed -i "s/127\.0\.0\.1/$IP_ADDR/g" /etc/memcached.conf
service memcached restart

#
# etcd
#
apt -y install etcd
mkdir -p /etc/etcd
cat > /etc/etcd/etcd.conf.yml <<EOF
name: controller
data-dir: /var/lib/etcd
initial-cluster-state: 'new'
initial-cluster-token: 'etcd-cluster-01'
initial-cluster: controller=http://$IP_ADDR:2380
initial-advertise-peer-urls: http://$IP_ADDR:2380
advertise-client-urls: http://$IP_ADDR:2379
listen-peer-urls: http://0.0.0.0:2380
listen-client-urls: http://$IP_ADDR:2379
EOF

cat > /lib/systemd/system/etcd.service <<EOF
[Unit]
After=network.target
Description=etcd - highly-available key value store

[Service]
LimitNOFILE=65536
Restart=on-failure
Type=notify
ExecStart=/usr/bin/etcd --config-file /etc/etcd/etcd.conf.yml
User=etcd

[Install]
WantedBy=multi-user.target
EOF
systemctl enable etcd
systemctl start etcd


#
# Keystone
#
mysql -sfu root <<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$KEYSTONE_DBPASS';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$KEYSTONE_DBPASS';
EOF
apt -y install keystone  apache2 libapache2-mod-wsgi
crudini --set /etc/keystone/keystone.conf database connection "mysql+pymysql://keystone:$KEYSTONE_DBPASS@controller/keystone"
crudini --set /etc/keystone/keystone.conf token provider fernet
su -s /bin/sh -c "keystone-manage db_sync" keystone
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
keystone-manage bootstrap --bootstrap-password $ADMIN_PASS \
  --bootstrap-admin-url http://$IP_ADDR:5000/v3/ \
  --bootstrap-internal-url http://$IP_ADDR:5000/v3/ \
  --bootstrap-public-url http://$IP_ADDR:5000/v3/ \
  --bootstrap-region-id RegionOne
sed -i '/ServerRoot/a ServerName controller' /etc/apache2/apache2.conf
service apache2 restart

cat > ~/admin-openrc <<EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

cat > ~/demo-openrc <<EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=$DEMO_PASS
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

source ~/admin-openrc
openstack domain create --description "An Example Domain" example
openstack project create --domain default --description "Service Project" service
openstack project create --domain default --description "Demo Project" demo
openstack user create --domain default --password $DEMO_PASS demo
openstack role create user
openstack role add --project demo --user demo user
openstack token issue

#
# Glance
#
mysql -sfu root <<EOF
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$GLANCE_DBPASS';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$GLANCE_DBPASS';
EOF
openstack user create --domain default --password $GLANCE_PASS glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image" image
openstack endpoint create --region RegionOne image public http://$IP_ADDR:9292
openstack endpoint create --region RegionOne image internal http://$IP_ADDR:9292
openstack endpoint create --region RegionOne image admin http://$IP_ADDR:9292
apt -y install glance
crudini --merge /etc/glance/glance-api.conf <<EOF
[database]
connection = mysql+pymysql://glance:$GLANCE_DBPASS@controller/glance

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = glance
password = $GLANCE_PASS

[paste_deploy]
flavor = keystone

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
EOF

crudini --merge /etc/glance/glance-registry.conf <<EOF
[database]
connection = mysql+pymysql://glance:$GLANCE_DBPASS@controller/glance

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = glance
password = $GLANCE_PASS

[paste_deploy]
flavor = keystone
EOF

su -s /bin/sh -c "glance-manage db_sync" glance
service glance-registry restart
service glance-api restart

source ~/admin-openrc
wget http://download.cirros-cloud.net/0.4.0/cirros-0.4.0-x86_64-disk.img -P ~/
openstack image create "cirros" \
  --file ~/cirros-0.4.0-x86_64-disk.img \
  --disk-format qcow2 --container-format bare \
  --public
openstack image list
