#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2017  Jan Schneider <oss@janschneider.net>
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#  hue api docs:
#    https://developers.meethue.com/documentation/getting-started

source /usr/local/addons/hue/lib/ini.tcl

namespace eval hue {
	variable ini_file "/usr/local/addons/hue/etc/hue.conf"
	variable log_file "/usr/local/addons/hue/log.txt"
	variable devicetype "homematic-addon-hue#ccu"
	variable curl "/usr/local/addons/cuxd/curl"
}

proc ::hue::convert_string_to_hex {str} {
	binary scan $str H* hex
	return $hex
}

proc ::hue::discover_bridges {} {
	variable curl
	set bridge_ips [list]
	set data [exec $curl --silent --insecure https://www.meethue.com/api/nupnp]
	foreach d [split $data "\}"] {
		set i ""
		regexp {"internalipaddress"\s*:\s*"([^"]+)"} $d match i
		if { [info exists i] && $i != "" } {
			lappend bridge_ips $i
		}
	}
	return $bridge_ips
}

proc ::hue::get_config_json {} {
	variable ini_file
	set ini [ini::open $ini_file r]
	set json "\{\"bridges\":\["
	set count 0
	foreach section [ini::sections $ini] {
		set idx [string first "bridge_" $section]
		if {$idx == 0} {
			set count [ expr { $count + 1} ]
			set bridge_id [string range $section 7 end]
			append json "\{\"id\":\"${bridge_id}\","
			foreach key [ini::keys $ini $section] {
				set value [::ini::value $ini $section $key]
				set value [json_string $value]
				append json "\"${key}\":\"${value}\","
			}
			set json [string range $json 0 end-1]
			append json "\},"
		}
	}
	if {$count > 0} {
		set json [string range $json 0 end-1]
	}
	append json "\]\}"
	return $json
}

proc ::hue::create_bridge {bridge_id name ip username} {
	variable ini_file
	set bridge_id [string tolower $bridge_id]
	set ini [ini::open $ini_file r+]
	ini::set $ini "bridge_${bridge_id}" "name" $name
	ini::set $ini "bridge_${bridge_id}" "ip" $ip
	ini::set $ini "bridge_${bridge_id}" "username" $username
	ini::set $ini "bridge_${bridge_id}" "port" "80"
	ini::commit $ini
}

proc ::hue::set_bridge_param {bridge_id param value} {
	variable ini_file
	set bridge_id [string tolower $bridge_id]
	set ini [ini::open $ini_file r+]
	ini::set $ini "bridge_${bridge_id}" $param $value
	ini::commit $ini
}

proc ::hue::get_bridge {bridge_id} {
	variable ini_file
	set bridge_id [string tolower $bridge_id]
	set bridge(id) ""
	set ini [ini::open $ini_file r]
	foreach section [ini::sections $ini] {
		set idx [string first "bridge_${bridge_id}" $section]
		if {$idx == 0} {
			set bridge(id) $bridge_id
			foreach key [ini::keys $ini $section] {
				set value [::ini::value $ini $section $key]
				set bridge($key) $value
			}
		}
	}
	if {![info exists bridge(key)]} {
		set bridge(key) ""
	}
	return [array get bridge]
}

proc ::hue::delete_bridge {bridge_id} {
	variable ini_file
	set bridge_id [string tolower $bridge_id]
	set ini [ini::open $ini_file r+]
	ini::delete $ini "bridge_${bridge_id}"
	ini::commit $ini
}

proc ::hue::http_request {ip port method path data} {
	set sock [socket $ip $port]
	puts $sock "${method} ${path} HTTP/1.1"
	puts $sock "Host: ${ip}:${port}"
	puts $sock "User-Agent: cuxd"
	puts $sock "Content-Type: application/json"
	puts $sock "Content-Length: [string length $data]"
	puts $sock ""
	puts -nonewline $sock $data
	flush $sock
	
	set response ""
	while {![eof $sock]} {
		gets $sock line
		if {$line == ""} {
			set response [read $sock]
		}
	}
	return $response
}

proc ::hue::api_request {ip port username method path {data ""}} {
	if {[string first "/" $path] == 0} {
		set path [string range $path 1 end]
	}
	set path "/api/${username}/${path}"
	return [http_request $ip $port $method $path $data]
}

proc ::hue::api_establish_link {ip port} {
	set response [http_request $ip $port "POST" "/api" "\{\"devicetype\":\"${hue::devicetype}\"\}"]
	regexp {"success":.*"username"\s*:\s*"([a-zA-Z0-9]+)"} $response match username
	if {[info exists username]} {
		return $username
	}
	error $response
}

proc ::hue::request {bridge_id method path {data ""}} {
	set abridge [get_bridge $bridge_id]
	array set bridge $abridge
	
	if {$bridge(id) == ""} {
		error "Hue bridge ${bridge_id} not configured"
	}
	if {$bridge(ip) == ""} {
		error "Hue bridge ${bridge_id} ip address not configured"
	}
	if {$bridge(username) == ""} {
		error "Hue bridge ${bridge_id} username not configured"
	}
	return [api_request $bridge(ip) $bridge(port) $bridge(username) $method $path $data]
}

proc ::hue::hue_command {bridge_id command args} {
	#error "${command} >${args}<" "Debug" 500
	set res [eval $command [list $bridge_id] [lrange $args 0 end]]
	return $res
}

#hue::api_register
#puts [hue::api_request "PUT" "lights/1/state" "\{\"on\":true,\"sat\":254,\"bri\":254,\"hue\":1000\}"]
#puts [hue::api_request "PUT" "lights/2/state" "\{\"on\":true,\"sat\":254,\"bri\":254,\"hue\":1000\}"]
#puts [hue::api_request "PUT" "lights/1/state" "\{\"alert\":\"select\"\}"]
#puts [hue::api_request "PUT" "lights/2/state" "\{\"alert\":\"select\"\}"]
#puts [hue::api_request "PUT" "lights/1/state" "\{\"effect\":\"colorloop\"\}"]
#puts [hue::api_request "PUT" "lights/2/state" "\{\"effect\":\"colorloop\"\}"]
#puts [hue::api_request "PUT" "lights/1/state" "\{\"effect\":\"none\"\}"]
#puts [hue::api_request "PUT" "lights/2/state" "\{\"effect\":\"none\"\}"]
#puts [hue::api_request "GET" "groups"]
#puts [hue::api_request "GET" "groups/1"]
#puts [hue::api_request "PUT" "groups/1/action" "\{\"on\":true\}"]
#puts [hue::api_request "GET" "config"]
#puts [hue::api_request "GET" "scenes"]
#puts [hue::api_request "PUT" "groups/1/action" "\{\"scene\":\"jXTvbsXs9KO8PVw\"\}"]

