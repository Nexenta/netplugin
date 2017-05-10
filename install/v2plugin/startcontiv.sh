#!/bin/sh

### Pre-requisite on the host
# run a cluster store like etcd or consul

if [ $log_dir == "" ]; then
    log_dir="/var/log/contiv"
fi
BOOTUP_LOGFILE="$log_dir/plugin_bootup.log"

mkdir -p $log_dir
mkdir -p /var/run/openvswitch
mkdir -p /etc/openvswitch

echo "V2 Plugin logs iflist='$iflist'" > $BOOTUP_LOGFILE

if [ -z $iflist ]; then
    echo "iflist is empty. Host interface(s) should be specified to use vlan mode" >> $BOOTUP_LOGFILE
else
    iflist_cfg="-vlan-if $iflist"
fi
if [ -z $iflist_rep ]; then
    echo "iflist_rep is empty. Host interface(s) should be specified to use rep vlan mode" >> $BOOTUP_LOGFILE
else
    iflist_rep_cfg="-repvlan-if $iflist_rep"
fi
if [ -z $iflist_repgw ]; then
    echo "iflist_repgw is empty. Host interface(s) should be specified to use repgw vlan mode" >> $BOOTUP_LOGFILE
else
    iflist_repgw_cfg="-repgwvlan-if $iflist_repgw"
fi
if [ $ctrl_ip != "none" ]; then
    ctrl_ip_cfg="-ctrl-ip=$ctrl_ip"
fi
if [ $vtep_ip != "none" ]; then
    vtep_ip_cfg="-vtep-ip=$vtep_ip"
fi
if [ $listen_url != ":9999" ]; then
    listen_url_cfg="-listen-url=$listen_url"
fi
if [ $control_url != ":9999" ]; then
    control_url_cfg="-control-url=$control_url"
fi
if [ $vxlan_port != "4789" ]; then
    vxlan_port_cfg="-vxlan-port=$vxlan_port"
fi

echo "Loading OVS" >> $BOOTUP_LOGFILE
(modprobe openvswitch) || (echo "Load ovs FAILED!!! " >> $BOOTUP_LOGFILE)

ovs_restart() {
    echo "  Cleaning up ovsdb files" >> $BOOTUP_LOGFILE
    rm -rf /var/run/openvswitch/*
    rm -rf /etc/openvswitch/conf.db
    rm -rf /etc/openvswitch/.conf.db.~lock~

    echo "  Creating OVS DB" >> $BOOTUP_LOGFILE
    (ovsdb-tool create  /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema) || (while true; do sleep 1; done)

    pkill -TERM -f ovs-vswitchd
    pkill -TERM -f ovsdb-server

    echo "  Starting OVSBD server " >> $BOOTUP_LOGFILE
    ovsdb-server --remote=punix:/var/run/openvswitch/db.sock --remote=db:Open_vSwitch,Open_vSwitch,manager_options --private-key=db:Open_vSwitch,SSL,private_key --certificate=db:Open_vSwitch,SSL,certificate --bootstrap-ca-cert=db:Open_vSwitch,SSL,ca_cert --log-file=$log_dir/ovs-db.log -vsyslog:dbg -vfile:dbg --pidfile --detach /etc/openvswitch/conf.db >> $BOOTUP_LOGFILE
    echo "  Starting ovs-vswitchd " >> $BOOTUP_LOGFILE
    ovs-vswitchd -v --pidfile --detach --log-file=$log_dir/ovs-vswitchd.log -vconsole:err -vsyslog:info -vfile:info &
    ovs-vsctl set-manager tcp:127.0.0.1:6640 
    ovs-vsctl set-manager ptcp:6640

    echo "Started OVS, logs in $log_dir" >> $BOOTUP_LOGFILE
    ovs-vsctl show >> $BOOTUP_LOGFILE
}

ovs_restart

ETCD_CONF_FILE="/etcd.yaml"
ETCD_DATA_DIR="/etcd.data"
ETCD_LLIF="nedge_rep"
ETCD_CLUSTER_NAME="nedge_rep_cluster"

neigh_members() {
    IPDISC=`ping6 -I $ETCD_LLIF ff02::1 -c1|awk '/bytes from fe80:/{print $4}'|sort -u`
    for IP in $IPDISC; do
        IP=`echo $IP|sed 's/:$//'`
        if [ "x$IPREP" == "x$IP" ]; then
            continue
        fi
        if [ "x$IPREPGW" == "x$IP" ]; then
            continue
        fi
        if [ "x$IPCLIENT" == "x$IP" ]; then
            continue
        fi
        NODENAME=`echo $IP|sed 's/:/_/g'`
        echo -n $NODENAME=http://[$IP%25$ETCD_LLIF]:2380","
    done
}

add_nedge_rep() {
    ovs-vsctl del-port $ETCD_LLIF $iflist_rep 2>/dev/null
    ovs-vsctl del-br $ETCD_LLIF 2>/dev/null
    ovs-vsctl --may-exist add-br $ETCD_LLIF 2>/dev/null
    ovs-vsctl --may-exist add-port $ETCD_LLIF $iflist_rep 2>/dev/null
    ip link set $ETCD_LLIF up
    sleep 2

    echo "Verifying availability of $ETCD_LLIF bridge:" >> $BOOTUP_LOGFILE
    ovs-vsctl show >> $BOOTUP_LOGFILE

    echo "Using $ETCD_LLIF for ETCD:" >> $BOOTUP_LOGFILE
    ifconfig $ETCD_LLIF >> $BOOTUP_LOGFILE
}

etcd_autodisc() {
    if [ ! -z $iflist ]; then
        IPCLIENT=`ip addr show $iflist|awk '/inet6.*fe80:/{print $2}'|awk -F/ '{print $1}'`
    fi
    if [ ! -z $iflist_repgw ]; then
        IPREPGW=`ip addr show $iflist_repgw|awk '/inet6.*fe80:/{print $2}'|awk -F/ '{print $1}'`
    fi
    IPREP=`ip addr show $iflist_rep|awk '/inet6.*fe80:/{print $2}'|awk -F/ '{print $1}'`
    IPLL=`ip addr show $ETCD_LLIF|awk '/inet6.*fe80:/{print $2}'|awk -F/ '{print $1}'`
    ETCD_NAME=`echo $IPLL|sed 's/:/_/g'`
    ETCD_CLUSTER_MEMBERS="`neigh_members`"

cat <<EOM >$ETCD_CONF_FILE
name: $ETCD_NAME
data-dir: $ETCD_DATA_DIR
initial-advertise-peer-urls: http://[$IPLL%25$ETCD_LLIF]:2380
listen-peer-urls: http://[$IPLL%25$ETCD_LLIF]:2380
listen-client-urls: http://[$IPLL%25$ETCD_LLIF]:2379
advertise-client-urls: http://[$IPLL%25$ETCD_LLIF]:2379
initial-cluster-token: $ETCD_CLUSTER_NAME
initial-cluster: $ETCD_CLUSTER_MEMBERS
initial-cluster-state: new
EOM

    echo "Auto-discovery completed IPLL=$IPLL, IPREP=$IPREP, IPREPGW=$IPREPGW, IPCLIENT=$IPCLIENT, created $ETCD_CONF_FILE" >> $BOOTUP_LOGFILE

    cluster_store="etcd://[$IPLL%25$ETCD_LLIF]:2379"
    echo "Overriding -cluster_store with $cluster_store" >> $BOOTUP_LOGFILE
}

if [ ! -z $iflist_rep ]; then

    echo "Starting Replicast ETCD, logs in $log_dir" >> $BOOTUP_LOGFILE

    while ! add_nedge_rep ; do
        echo "Restarting OVS, logs in $log_dir" >> $BOOTUP_LOGFILE
        ovs_restart
    done
    etcd_autodisc

    mkdir -p $ETCD_DATA_DIR

    echo "Starting etcd --config-file=$ETCD_CONF_FILE" >> $BOOTUP_LOGFILE
    while true ; do
        etcd --config-file="$ETCD_CONF_FILE" >> $log_dir/etcd.log 2>&1
        echo "CRITICAL : ETCD has exited err=$?, Respawn in 2s" >> $BOOTUP_LOGFILE
        mv $log_dir/etcd.log $log_dir/etcd.log.lastrun
        sleep 2
        echo "Restarting ETCD, logs in $log_dir" >> $BOOTUP_LOGFILE
    done &
    sleep 1
fi

echo "Starting Netplugin " >> $BOOTUP_LOGFILE
while true ; do
    echo "/netplugin $dbg_flag -plugin-mode $plugin_mode $vxlan_port_cfg $iflist_cfg $iflist_rep_cfg $iflist_repgw_cfg -cluster-store $cluster_store $ctrl_ip_cfg $vtep_ip_cfg" >> $BOOTUP_LOGFILE
    /netplugin $dbg_flag -plugin-mode $plugin_mode $vxlan_port_cfg $iflist_cfg $iflist_rep_cfg $iflist_repgw_cfg  -cluster-store $cluster_store $ctrl_ip_cfg $vtep_ip_cfg &> $log_dir/netplugin.log
    echo "CRITICAL : Net Plugin has exited err=$?, Respawn in 5" >> $BOOTUP_LOGFILE
    mv $log_dir/netplugin.log $log_dir/netplugin.log.lastrun
    sleep 5
    echo "Restarting Netplugin " >> $BOOTUP_LOGFILE
done &

if [ $plugin_role == "master" ]; then
    echo "Starting Netmaster " >> $BOOTUP_LOGFILE
    while  true ; do
        echo "/netmaster $dbg_flag -plugin-name=$plugin_name -cluster-mode=$plugin_mode -cluster-store=$cluster_store $listen_url_cfg $control_url_cfg" >> $BOOTUP_LOGFILE
        /netmaster $dbg_flag -plugin-name=$plugin_name -cluster-mode=$plugin_mode -cluster-store=$cluster_store $listen_url_cfg $control_url_cfg &> $log_dir/netmaster.log
        echo "CRITICAL : Net Master has exited err=$?, Respawn in 5s" >> $BOOTUP_LOGFILE
	mv $log_dir/netmaster.log $log_dir/netmaster.log.lastrun
        sleep 5
        echo "Restarting Netmaster " >> $BOOTUP_LOGFILE
    done &
else
    echo "Not starting netmaster as plugin role is" $plugin_role >> $BOOTUP_LOGFILE
fi

while true; do sleep 1; done

