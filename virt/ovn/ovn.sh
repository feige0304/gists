set -x

logdir=/home/yousong/.usr/var/log/openvswitch
rundir=/home/yousong/.usr/var/run/openvswitch

o_north_sb_ip=10.4.237.52
o_north_sb_port=6642
o_north_nb_ip=10.4.237.52
o_north_nb_port=6641

ovn_nbctl() {
	ovn-nbctl --db="tcp:$o_north_nb_ip:$o_north_nb_port" "$@"
}

get_encap_ip() {
	ip -o addr show dev eth1 | grep -oE 'inet [^/ ]+' | cut -d' ' -f2
}

get_dhcp_uuid() {
	ovn_nbctl --bare --columns=_uuid find DHCP_Options cidr=192.168.2.0/24
}

prep_host() {
	local encap_ip="$(get_encap_ip)"

	ovs-ctl start --system-id=random
	ovn-ctl start_controller

	ovs-vsctl set Open_vSwitch . \
		external_ids:ovn-remote="tcp:$o_north_sb_ip:$o_north_sb_port" \
		external_ids:ovn-bridge=br0 \
		external_ids:ovn-encap-type=geneve \
		external_ids:ovn-encap-ip="$encap_ip" \

}

prep_north() {
	ovn-ctl start_northd \
		--db-nb-create-insecure-remote \
		--db-sb-create-insecure-remote

	# logical switch name does not need to be unique
	# logical switch port name needs to be unique: iface-id
	ovn_nbctl \
		-- --all destroy DHCP_Options \
		-- --all destroy Logical_Switch \
		-- --all destroy Logical_Switch_Port \

	ovn_nbctl create DHCP_Options \
				cidr=192.168.2.0/24 \
				options:server_id=192.168.2.1 \
				options:server_mac=0a:00:00:00:00:01 \
				options:lease_time=86400

	ovn_nbctl \
		-- --id=@ls0 create Logical_Switch  \
			name=ls0 \
			other-config:subnet=192.168.2.0/24 \

}

prep_logical() {
	add_logical_port ls0p0 0a:00:00:00:00:02 192.168.2.2
	add_logical_port ls0p1 0a:00:00:00:00:03 192.168.2.3
	add_logical_port ls0p2 0a:00:00:00:00:04 192.168.2.4
}

add_logical_port() {
	local name="$1"; shift
	local mac="$1"; shift
	local ip="$1"; shift

	local dhcp="$(get_dhcp_uuid)"
	ovn_nbctl --may-exist lsp-add ls0 "$name" \
		-- lsp-set-addresses "$name" "$mac $ip" \
		-- lsp-set-dhcpv4-options "$name" $dhcp \

}

add_host_port() {
	local name="$1"; shift
	local mac="$1"; shift
	local ip="$1"; shift
	local name0="${name}0"
	local name1="${name}1"

	# openvswitch internal type port may not work for it cannot be put to
	# ofport up state
	ip netns add "$name"
	ip link del dev "$name0"
	ip link add dev "$name0" type veth peer name "$name1"
	ip link set dev "$name0" up
	ip link set dev "$name1" netns "$name" address "$mac" up

	ovs-vsctl --if-exists del-port "$name0"
	ovs-vsctl --may-exist add-port br0 "$name0" \
		-- set Interface "$name0" external_ids:iface-id="$name"

	ip netns exec "$name" timeout 3 dhclient -d "$name1"
}

init_host0() {
	add_host_port ls0p0 0a:00:00:00:00:02 192.168.2.2
	add_host_port ls0p1 0a:00:00:00:00:03 192.168.2.3
}


init_host1() {
	add_host_port ls0p2 0a:00:00:00:00:04 192.168.2.4
}

# prep_north
# prep_host
# prep_logical
# init_host0
# init_host1
"$@"