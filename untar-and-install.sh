#!/bin/bash

echo "Installing apt packages..."
sudo apt-get install ipset conntrack libvirt-dev pkg-config arping haproxy liberasurecode-dev libmysqlclient-dev
#sudo pip install -U pip
#sudo pip install setuptools==38.7.0 gevent==1.0.2 pymysql mysqlclient python-neutronclient==5.1.0
echo

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "WARNING: This script and tar files assumes nova and neutron directories are located in /opt/stack/"
echo "         If this is not the case, have to resort back to manually editing paths of virtualenvs..."
echo
read -p "Press ENTER to continue..." ASDFASDF

echo
echo "Renaming old nova and neutron directories..."
mv /opt/stack/nova /opt/stack/nova.newton
mv /opt/stack/neutron /opt/stack/neutron.newton

echo
echo "Untar'ing new directories..."
tar -xvf ${SCRIPT_DIR}/nova-queens.tar.gz -C /opt/stack/
tar -xvf ${SCRIPT_DIR}/neutron-queens.tar.gz -C /opt/stack/

echo
echo "Copying nova binaries..."
cd /opt/stack/nova && sudo cp bin/nova-* /usr/local/bin/

echo
echo "Copying neutron binaries..."
cd /opt/stack/neutron && sudo cp bin/neutron-* /usr/local/bin

echo
# Nova's privsep-helper should have "develop"'d paths to neutron's virtualenv as well
echo "Updating privsep-helper..."
cd /opt/stack/nova && sudo cp bin/privsep-helper /usr/local/bin

echo
echo "Renaming old nova rootwrap configurations..."
sudo mv /etc/nova/rootwrap.conf /etc/nova/rootwrap.conf.newton
sudo mv /etc/nova/rootwrap.d /etc/nova/rootwrap.d.newton

echo "Renaming old neutron rootwrap configurations..."
sudo mv /etc/neutron/rootwrap.conf /etc/neutron/rootwrap.conf.newton
sudo mv /etc/neutron/rootwrap.d /etc/neutron/rootwrap.d.newton

echo "Copying over new nova rootwrap configurations..."
sudo cp -r /opt/stack/nova/etc/nova/rootwrap.* /etc/nova/

echo "Copying over new neutron rootwrap configurations..."
sudo cp -r /opt/stack/neutron/etc/neutron/rootwrap.d /etc/neutron/
sudo cp /opt/stack/neutron/etc/rootwrap.conf /etc/neutron/


echo
read -p "What is this region's name? => " REGION_NAME
read -p "Does this region use IAM v2 or v3? (Enter '2' or '3') => " IAMVERS
while [[ 1 ]]; do
    if [[ ${IAMVERS} -ne 2 && ${IAMVERS} -ne 3 ]]; then
        echo "Unknown response"
        read -p "Does this region use IAM v2 or v3? (Enter '2' or '3') => " IAMVERS
    else
        break;
    fi
done

echo
read -p "What is the controller's internal management IP? => " CTRL_IP
echo

echo
echo "Updating janus-ovsdb..."
mv /opt/stack/janus-ovsdb /opt/stack/janus-ovsdb.old
git clone https://github.com/savi-dev/janus-ovsdb.git /opt/stack/janus-ovsdb
if [[ ${IAMVERS} -eq 2 ]]; then
    sudo cp ${SCRIPT_DIR}/jovs_config-iamv2.py /opt/stack/janus-ovsdb/jovs_config.py
elif [[ ${IAMVERS} -eq 3 ]]; then
    sudo cp ${SCRIPT_DIR}/jovs_config-iamv3.py /opt/stack/janus-ovsdb/jovs_config.py
else
    echo "Uh oh, shouldn't be here"
    exit 1
fi
sudo sed -i '1s/^/#!\/opt\/stack\/neutron\/bin\/python\n/g' /opt/stack/janus-ovsdb/ovsdb.py

echo
echo "Re-writing region name and controller IP for jovs_config.py..."
sudo sed -i "s/REGION_NAME/${REGION_NAME}/g" /opt/stack/janus-ovsdb/jovs_config.py
sudo sed -i "s/CTRL_IP/${CTRL_IP}/g" /opt/stack/janus-ovsdb/jovs_config.py

echo
read -p "Is this node a controller or agent? (Enter 'controller' or 'agent') => " NODETYPE
while [[ 1 ]]; do
    if [[ "${NODETYPE}" != "controller" && "${NODETYPE}" != "agent" ]]; then
        echo "Unknown response"
        read -p "Is this node a controller or agent? (Enter 'controller' or 'agent') => " NODETYPE
    else
        break;
    fi
done

echo "Renaming old nova and neutron configurations..."
sudo mv /etc/nova/nova.conf /etc/nova/nova.conf.newton
sudo mv /etc/nova/api-paste.ini /etc/nova/api-paste.ini.newton
sudo mv /etc/neutron/neutron.conf /etc/neutron/neutron.conf.newton
sudo mv /etc/neutron/api-paste.ini /etc/neutron/api-paste.ini.newton
sudo mv /etc/neutron/policy.json /etc/neutron/policy.json.newton

echo "Copying over new nova and neutron configurations..."
sudo cp /opt/stack/nova/etc/nova/api-paste.ini /etc/nova/
sudo cp /opt/stack/neutron/etc/api-paste.ini /etc/neutron/

if [[ "${NODETYPE}" == "controller" ]]; then
    sudo cp ${SCRIPT_DIR}/controller/nova.conf /etc/nova/
    sudo cp ${SCRIPT_DIR}/controller/neutron.conf /etc/neutron/
    sudo cp ${SCRIPT_DIR}/controller/policy.json /etc/neutron/

    echo "Re-writing IPs..."
    sudo sed -i "s/CTRL_IP/${CTRL_IP}/g" /etc/neutron/neutron.conf
    sudo sed -i "s/CTRL_IP/${CTRL_IP}/g" /etc/nova/nova.conf

    echo
    echo "Replacing stack-screenrc..."
    mv ~/devstack/stack-screenrc ~/devstack/stack-screenrc.newton
    cp ${SCRIPT_DIR}/controller/stack-screenrc ~/devstack/
    ROUTERID=`mysql -sN -e "USE neutron; SELECT id FROM routers;"`
    if [[ `echo ${ROUTERID} | wc -l` -ne 1 || -z ${ROUTERID} ]]; then
        echo "ERROR: Something went wrong trying to find the Neutron router's ID..."
        echo "       Must manually figure out which one should be QR and edit stack-screenrc's arp_handler line"
        exit 0
    fi
    sed -i "s/QR_NS/${ROUTERID}/g" ~/devstack/stack-screenrc
elif [[ "${NODETYPE}" == "agent" ]]; then
    sudo cp ${SCRIPT_DIR}/agent/nova.conf /etc/nova/
    sudo cp ${SCRIPT_DIR}/agent/neutron.conf /etc/neutron/
    sudo cp ${SCRIPT_DIR}/agent/ml2_conf.ini /etc/neutron/plugins/ml2/

    # Get public IP address
    # Ideally this should be the FQDN of the controller
    CTRL_PUB_IP=`curl -s ipconfig.io`

    read -p "What is this agent's internal management IP? => " AGENT_IP
    echo

    echo "Re-writing IPs..."
    sudo sed -i "s/CTRL_IP/${CTRL_IP}/g" /etc/neutron/neutron.conf
    sudo sed -i "s/CTRL_IP/${CTRL_IP}/g" /etc/nova/nova.conf
    sudo sed -i "s/CTRL_PUB_IP/${CTRL_PUB_IP}/g" /etc/nova/nova.conf
    sudo sed -i "s/AGENT_IP/${AGENT_IP}/g" /etc/nova/nova.conf
    sudo sed -i "s/AGENT_IP/${AGENT_IP}/g" /etc/neutron/plugins/ml2/ml2_conf.ini

    if [[ ! -d ~/devstack ]]; then
        cp -r ${SCRIPT_DIR}/simple-agent-devstack ~/devstack
    fi
else
    echo "Uh oh, shouldn't be here"
    exit 1
fi

echo "Re-writing region name..."
sudo sed -i "s/REGION_NAME/${REGION_NAME}/g" /etc/nova/nova.conf
sudo sed -i "s/REGION_NAME/${REGION_NAME}/g" /etc/neutron/neutron.conf

if [[ ${IAMVERS} -eq 3 ]]; then
    echo "Updating IAM endpoint..."
    sudo sed -i "s/iam.savitestbed.ca:35357\/v2.0/iamv3.savitestbed.ca\/identity_v2_admin/g" /etc/nova/nova.conf
    sudo sed -i "s/iam.savitestbed.ca:35357\/v2.0/iamv3.savitestbed.ca\/identity_v2_admin/g" /etc/neutron/neutron.conf
fi

echo
read -p "What is RabbitMQ's password within this region? => " RABBITPW
read -p "What is MySQL's password within this region? => " MYSQLPW
read -p "What is the OpenStack 'service' user password? => " SERVICEPW
echo

echo "Updating passwords in nova and neutron config files, and jovs_config.py..."
sudo sed -i "s/MYSQLPW/${MYSQLPW}/g" /etc/nova/nova.conf
sudo sed -i "s/RABBITPW/${RABBITPW}/g" /etc/nova/nova.conf
sudo sed -i "s/SERVICEPW/${SERVICEPW}/g" /etc/nova/nova.conf
sudo sed -i "s/MYSQLPW/${MYSQLPW}/g" /etc/neutron/neutron.conf
sudo sed -i "s/RABBITPW/${RABBITPW}/g" /etc/neutron/neutron.conf
sudo sed -i "s/SERVICEPW/${SERVICEPW}/g" /etc/neutron/neutron.conf
sudo sed -i "s/SERVICEPW/${SERVICEPW}/g" /opt/stack/janus-ovsdb/jovs_config.py
sudo sed -i "s/RABBITPW/${RABBITPW}/g" /opt/stack/janus-ovsdb/jovs_config.py

echo
echo "WARNING: SOME PASSWORDS (Rabbit, MySQL) ARE STORED IN NOVA_API'S 'cell_mappings' TABLE, MAY NEED TO BE MANUALLY CHANGED"
echo
echo "REMINDER: Must have also pre-created the Placement API endpoint in Keystone catalog"
echo
echo "Done!"
