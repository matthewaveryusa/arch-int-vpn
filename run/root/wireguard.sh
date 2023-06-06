#!/bin/bash

function pia_create_wireguard_keys() {

	# create ephemeral wireguard private and public keys
	wireguard_private_key=$(wg genkey)
	wireguard_public_key=$(echo "${wireguard_private_key}" | wg pubkey)

}

function pia_generate_token() {

	retry_count=12
	retry_wait_secs=10

	while true; do

		if [[ "${retry_count}" -eq "0" ]]; then

			if [[ "${VPN_CLIENT}" -eq "wireguard" ]]; then

				echo "[crit] Unable to successfully download PIA json to generate token for wireguard, exiting script..."
				exit 1

			fi

		fi

		# get token json response, this is required for wireguard connection
		token_json_response=$(curl --silent --insecure -u "${VPN_USER}:${VPN_PASS}" "https://www.privateinternetaccess.com/gtoken/generateToken")

		if [ "$(echo "${token_json_response}" | jq -r '.status')" != "OK" ]; then

			echo "[warn] Unable to successfully download PIA json to generate token for wireguard from URL 'https://www.privateinternetaccess.com/gtoken/generateToken'"
			echo "[info] ${retry_count} retries left"
			echo "[info] Retrying in ${retry_wait_secs} secs..."
			retry_count=$((retry_count-1))
			sleep "${retry_wait_secs}"s & wait $!

		else

			echo "[info] Token generated for PIA wireguard authentication"
			token=$(echo "${token_json_response}" | jq -r '.token')
			break

		fi

	done

	if [[ "${DEBUG}" == "true" ]]; then

		echo "[debug] PIA generated 'token' for wireguard is '${token}'"

	fi

}

function pia_wireguard_authenticate() {

	# authenticate via the pia wireguard restful api
	# this will return json with data required for authentication.
	echo "[info] Trying to connect to the PIA WireGuard API on '${VPN_REMOTE_SERVER}'..."
	pia_wireguard_authentication_json=$(curl --silent --get --insecure --data-urlencode "pt=${token}" --data-urlencode "pubkey=${wireguard_public_key}" "https://${VPN_REMOTE_SERVER}:1337/addKey")

}

function pia_get_wireguard_config() {

	pia_wireguard_peer_ip=$(echo "${pia_wireguard_authentication_json}" | jq -r '.peer_ip')
	pia_wireguard_server_key=$(echo "$pia_wireguard_authentication_json" | jq -r '.server_key')

	# commented line below is legacy method for getting server port, now moved to init.sh,
	# but keeping the below line in case we need to switch to the previous method
	#pia_wireguard_server_port=$(echo "$pia_wireguard_authentication_json" | jq -r '.server_port')

	# this is the gateway ip for wireguard, this is required in getvpnport.sh, which is called
	# as part of the wireguardup.sh.
	export vpn_gateway_ip=$(echo "$pia_wireguard_authentication_json" | jq -r '.server_vip')

	if [[ "${DEBUG}" == "true" ]]; then

		echo "[debug] PIA WireGuard 'peer ip' is '${pia_wireguard_peer_ip}'"
		echo "[debug] PIA WireGuard 'server key' is '${pia_wireguard_server_key}'"
		echo "[debug] PIA WireGuard 'server vip' (gsteway) is '${vpn_gateway_ip}'"

	fi

}

function pia_create_wireguard_config_file() {

	# get pia wireguard server ip address for hostname using hosts
	# file lookup (hosts file entry created in start.sh)
	#pia_wireguard_server_ip=$(getent hosts "${VPN_REMOTE_SERVER}" | awk '{ print $1 }')

cat <<EOF > "${VPN_CONFIG}"

[Interface]
Address = ${pia_wireguard_peer_ip}
PrivateKey = ${wireguard_private_key}
PostUp = '/root/wireguardup.sh'
PostDown = '/root/wireguarddown.sh'

[Peer]
PublicKey = ${pia_wireguard_server_key}
AllowedIPs = 0.0.0.0/0
Endpoint = ${VPN_REMOTE_SERVER}:${VPN_REMOTE_PORT}

EOF

}

function watchdog() {

	# loop and watch out for files generated by user nobody scripts that indicate failure
	while true; do

		# reset flag, used to indicate connection status
		down="false"

		# if '/tmp/portclosed' file exists (generated by /home/nobody/watchdog.sh when incoming port
		# detected as closed) then down wireguard
		if [ -f "/tmp/portclosed" ]; then

			echo "[info] Sending 'down' command to WireGuard due to port closed..."
			down="true"
			rm -f "/tmp/portclosed"

		fi

		# if '/tmp/dnsfailure' file exists (generated by /home/nobody/checkdns.sh when dns fails)
		# then down wireguard
		if [ -f "/tmp/dnsfailure" ]; then

			echo "[info] Sending 'down' command to WireGuard due to dns failure..."
			down="true"
			rm -f "/tmp/dnsfailure"

		fi

		# if '/tmp/portfailure' file exists (generated by /root/getvpnport.sh when incoming port
		# allocation fails) then down wireguard
		if [ -f "/tmp/portfailure" ]; then

			echo "[info] Sending 'down' command to WireGuard due to incoming port allocation failure..."
			down="true"
			rm -f "/tmp/portfailure"

		fi

		if [ "${down}" == "true" ]; then

			if [ -f '/tmp/endpoints' ]; then

				# read in associative array of endpint names and ip addresses from file created from function resolve_vpn_endpoints in /root/tools.sh
				source '/tmp/endpoints'

				for i in "${!vpn_remote_array[@]}"; do

					endpoint_name="${i}"
					endpoint_ip_array=( "${vpn_remote_array[$i]}" )

					# run function to round robin the endpoint ip and write to /etc/hosts
					round_robin_endpoint_ip "${endpoint_name}" "${endpoint_ip_array[@]}"

				done

			fi

		fi

		# if flagged by above scripts then down vpn tunnel
		if [ "${down}" == "true" ]; then
			down_wireguard
		fi

		# check if wireguard 'peer' exists, if not assume wireguard connection is down and bring up
		wg show | grep --quiet 'peer'
		if [ "${?}"  -ne 0 ]; then

			# run wireguard, will run as daemon background process
			up_wireguard

		fi

		sleep 30s

	done

}

function edit_wireguard() {

	# delete any existing PostUp/PostDown scripts (cannot easily edit and replace lines without insertion)
	sed -i -r '/.*PostUp = .*|.*PostDown = .*/d' "${VPN_CONFIG}"

	# insert PostUp/PostDown script lines after [Interface]
	sed -i -e "/\[Interface\]/a PostUp = '/root/wireguardup.sh'\nPostDown = '/root/wireguarddown.sh'" "${VPN_CONFIG}"

	# removes all ipv6 address and port from wireguard config
	sed -r -i -e 's/,?(\s+)?[a-f0-9]{4}::?[^,]+(\s+)?,?//g' "${VPN_CONFIG}"

	# removes all ipv6 port only from wireguard config
	sed -r -i -e 's/,?(\s+)?::[^,]+(\s+)?,?//g' "${VPN_CONFIG}"

}

function up_wireguard() {

	echo "[info] Rerunning wireguard authentication..."
	start_wireguard

	echo "[info] Attempting to bring WireGuard interface 'up'..."
	wg-quick up "${VPN_CONFIG}"
	if [ "${?}" -eq 0 ]; then
		echo "[info] WireGuard interface 'up'"
	else
		echo "[warn] WireGuard interface failed to come 'up', exit code is '${?}'"
	fi

}

function down_wireguard() {

	echo "[info] Attempting to bring WireGuard interface 'down'..."
	wg-quick down "${VPN_CONFIG}"
	if [ "${?}" -eq 0 ]; then
		echo "[info] WireGuard interface 'down'"
	else
		echo "[warn] WireGuard interface failed to bring 'down', exit code is '${?}'"
	fi

}

function start_wireguard() {

	# if vpn provider is pia then get required dynamic configuration and write to wireguard config file
	if [[ "${VPN_PROV}" == "pia" ]]; then

		pia_create_wireguard_keys
		pia_generate_token
		pia_wireguard_authenticate
		pia_get_wireguard_config
		pia_create_wireguard_config_file

	else

		# edit wireguard config to remove ipv6, required for mullvad and possibly other non pia
		# vpn providers
		edit_wireguard

	fi

	# setup ip tables and routing for application
	source /root/iptable.sh

}

# source in resolve dns and round robin ip's from functions
source '/root/tools.sh'

# kick off start
start_wireguard

# start watchdog function
watchdog
