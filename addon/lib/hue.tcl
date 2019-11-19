#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2019  Jan Schneider <oss@janschneider.net>
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

load tclrega.so
load tclrpc.so

source /usr/local/addons/hue/lib/ini.tcl

namespace eval hue {
	variable version_file "/usr/local/addons/hue/VERSION"
	variable ini_file "/usr/local/addons/hue/etc/hue.conf"
	variable log_file "/tmp/hue-addon-log.txt"
	variable log_level 0
	variable api_log "off"
	variable max_log_size 1000000
	# api_connect_timeout in milliseconds, 0=default tcl behaviour
	variable api_connect_timeout 0
	variable lock_start_port 11200
	variable lock_socket
	variable lock_id_log_file 1
	variable lock_id_ini_file 2
	variable lock_id_bridge_start 3
	variable poll_state_interval 5
	variable ignore_unreachable 0
	variable devicetype "homematic-addon-hue#ccu"
	variable curl "/usr/local/addons/cuxd/curl"
	variable cuxd_ps "/usr/local/addons/cuxd/cuxd.ps"
	variable cuxd_xmlrpc_url "xmlrpc_bin://127.0.0.1:8701"
	variable hued_address "127.0.0.1"
	variable hued_port 1919
}


proc json_string {str} {
	set replace_map {
		"\"" "\\\""
		"\\" "\\\\"
		"\b"  "\\b"
		"\f"  "\\f"
		"\n"  "\\n"
		"\r"  "\\r"
		"\t"  "\\t"
	}
	return "[string map $replace_map $str]"
}

# error=1, warning=2, info=3, debug=4
proc ::hue::write_log {lvl str {lock 1}} {
	variable log_level
	variable log_file
	variable lock_id_log_file
	variable max_log_size
	if {$lvl <= $log_level} {
		if {$lock == 1} {
			acquire_lock $lock_id_log_file
		}
		set fd [open $log_file "a"]
		set date [clock seconds]
		set date [clock format $date -format {%Y-%m-%d %T}]
		set process_id [pid]
		puts $fd "\[${lvl}\] \[${date}\] \[${process_id}\] ${str}"
		close $fd
		#puts "\[${lvl}\] \[${date}\] \[${process_id}\] ${str}"
		if {[file size $log_file] > $max_log_size} {
			set fd [open $log_file r]
			seek $fd [expr {$max_log_size / 4}]
			set data [read $fd]
			close $fd
			
			set data [string range $data [expr {[string first "\n" $data] + 1}] end]
			
			set fd [open $log_file "w"]
			puts -nonewline $fd $data
			close $fd
		}
		if {$lock == 1} {
			release_lock $lock_id_log_file
		}
	}
}

proc ::hue::read_log {} {
	variable log_file
	if { ![file exist $log_file] } {
		return ""
	}
	set fd [open $log_file "r"]
	set data [read $fd]
	close $fd
	return $data
}

proc ::hue::truncate_log {} {
	variable log_file
	variable lock_id_log_file
	acquire_lock $lock_id_log_file
	close [open $log_file "w"]
	release_lock $lock_id_log_file
}

proc ::hue::version {} {
	variable version_file
	set fd [open $version_file r]
	set data [read $fd]
	close $fd
	return [string trim $data]
}

proc ::hue::acquire_lock {lock_id} {
	variable lock_socket
	variable lock_start_port
	set port [expr { $lock_start_port + $lock_id }]
	set tn 0
	# 'socket already in use' error will be our lock detection mechanism
	#write_log 0 "acquire lock ${lock_id}" 0
	while {1} {
		set tn [expr {$tn + 1}]
		if { [catch {socket -server dummy_accept $port} sock] } {
			if {$tn > 250} {
				write_log 1 "Failed to acquire lock ${lock_id} after 2500ms, ignoring lock" 0
				break
			}
			after 10
		} else {
			set lock_socket($lock_id) $sock
			break
		}
	}
}

proc ::hue::acquire_bridge_lock {bridge_id} {
	variable lock_id_bridge_start
	set lock_id [ expr { $lock_id_bridge_start + [get_bridge_num $bridge_id] } ]
	acquire_lock $lock_id
}

proc ::hue::release_lock {lock_id} {
	variable lock_socket
	if {[info exists lock_socket($lock_id)]} {
		if { [catch {close $lock_socket($lock_id)} errormsg] } {
			write_log 1 "Error '${errormsg}' on closing socket for lock '${lock_id}'" 0
		}
		unset lock_socket($lock_id)
	}
}

proc ::hue::release_bridge_lock {bridge_id} {
	variable lock_id_bridge_start
	set lock_id [ expr { $lock_id_bridge_start + [get_bridge_num $bridge_id] } ]
	release_lock $lock_id
}

proc ::hue::convert_string_to_hex {str} {
	binary scan $str H* hex
	return $hex
}

proc ::hue::hued_command {command {params {}}} {
	variable hued_address
	variable hued_port
	set params [join $params " "]
	hue::write_log 4 "Sending command to hued: ${command} ${params}"
	set chan [socket $hued_address $hued_port]
	puts $chan "${command} ${params}"
	flush $chan
	set res [gets $chan]
	hue::write_log 4 "Command response from hued: $res"
	close $chan
	return $res
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

proc ::hue::get_bridge_num {bridge_id} {
	variable ini_file
	variable lock_id_ini_file
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r]
	set num 0
	foreach section [ini::sections $ini] {
		set idx [string first "bridge_" $section]
		if {$idx == 0} {
			set num [ expr { $num + 1} ]
			if {[string range $section 7 end] == $bridge_id} {
				break
			}
		}
	}
	ini::close $ini
	release_lock $lock_id_ini_file
	return $num
}

proc ::hue::get_config_bridge_ids {} {
	variable ini_file
	variable lock_id_ini_file
	acquire_lock $lock_id_ini_file
	set bridge_ids [list]
	set ini [ini::open $ini_file r]
	foreach section [ini::sections $ini] {
		set idx [string first "bridge_" $section]
		if {$idx == 0} {
			lappend bridge_ids [string range $section 7 end]
		}
	}
	ini::close $ini
	release_lock $lock_id_ini_file
	return $bridge_ids
}

proc ::hue::update_global_config {log_level api_log poll_state_interval ignore_unreachable api_connect_timeout} {
	variable ini_file
	variable lock_id_ini_file
	write_log 4 "Updating global config: log_level=${log_level} api_log=${api_log} poll_state_interval=${poll_state_interval} ignore_unreachable=${ignore_unreachable} api_connect_timeout=${api_connect_timeout}"
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r+]
	ini::set $ini "global" "log_level" $log_level
	ini::set $ini "global" "api_log" $api_log
	ini::set $ini "global" "api_connect_timeout" $api_connect_timeout
	ini::set $ini "global" "poll_state_interval" $poll_state_interval
	if {$ignore_unreachable == "true" || $ignore_unreachable == "1"} {
		ini::set $ini "global" "ignore_unreachable" "1"
	} else {
		ini::set $ini "global" "ignore_unreachable" "0"
	}
	ini::commit $ini
	release_lock $lock_id_ini_file
}

proc ::hue::read_global_config {} {
	variable ini_file
	variable lock_id_ini_file
	variable log_level
	variable api_log
	variable api_connect_timeout
	variable poll_state_interval
	variable ignore_unreachable
	
	write_log 4 "Reading global config"
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r]
	catch {
		set log_level [expr { 0 + [::ini::value $ini "global" "log_level" $log_level] }]
		set api_log [::ini::value $ini "global" "api_log" $api_log]
		set api_connect_timeout [expr { 0 + [::ini::value $ini "global" "api_connect_timeout" $api_connect_timeout] }]
		set poll_state_interval [expr { 0 + [::ini::value $ini "global" "poll_state_interval" $poll_state_interval] }]
		set ignore_unreachable [expr { 0 + [::ini::value $ini "global" "ignore_unreachable" $ignore_unreachable] }]
	}
	ini::close $ini
	release_lock $lock_id_ini_file
}

proc ::hue::get_config_json {} {
	variable ini_file
	variable lock_id_ini_file
	variable log_level
	variable api_log
	variable api_connect_timeout
	variable poll_state_interval
	variable ignore_unreachable
	
	set iu "false"
	if {$ignore_unreachable} {
		set iu "true"
	}
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r]
	set json "\{\"global\":\{\"log_level\":${log_level},\"api_log\":\"${api_log}\",\"api_connect_timeout\":${api_connect_timeout},\"poll_state_interval\":${poll_state_interval},\"ignore_unreachable\":${iu}\},\"bridges\":\["
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
	ini::close $ini
	if {$count > 0} {
		set json [string range $json 0 end-1]
	}
	append json "\]\}"
	release_lock $lock_id_ini_file
	return $json
}

proc ::hue::create_bridge {bridge_id name ip username} {
	variable ini_file
	variable lock_id_ini_file
	acquire_lock $lock_id_ini_file
	set bridge_id [string tolower $bridge_id]
	set ini [ini::open $ini_file r+]
	ini::set $ini "bridge_${bridge_id}" "name" $name
	ini::set $ini "bridge_${bridge_id}" "ip" $ip
	ini::set $ini "bridge_${bridge_id}" "username" $username
	ini::set $ini "bridge_${bridge_id}" "port" "80"
	ini::commit $ini
	release_lock $lock_id_ini_file
}

proc ::hue::set_bridge_param {bridge_id param value} {
	variable ini_file
	variable lock_id_ini_file
	acquire_lock $lock_id_ini_file
	set bridge_id [string tolower $bridge_id]
	set ini [ini::open $ini_file r+]
	ini::set $ini "bridge_${bridge_id}" $param $value
	ini::commit $ini
	release_lock $lock_id_ini_file
}

proc ::hue::get_bridge_param {bridge_id param} {
	variable ini_file
	variable lock_id_ini_file
	acquire_lock $lock_id_ini_file
	set bridge_id [string tolower $bridge_id]
	set ini [ini::open $ini_file r]
	set value ""
	catch {
		set value [ini::value $ini "bridge_${bridge_id}" $param]
	}
	ini::close $ini
	release_lock $lock_id_ini_file
	return $value
}

proc ::hue::get_bridge {bridge_id} {
	variable ini_file
	variable lock_id_ini_file
	acquire_lock $lock_id_ini_file
	set bridge_id [string tolower $bridge_id]
	set bridge(id) ""
	set ini [ini::open $ini_file r]
	foreach section [ini::sections $ini] {
		set idx [string first "bridge_${bridge_id}" $section]
		if {$idx == 0} {
			set bridge(id) $bridge_id
			foreach key [ini::keys $ini $section] {
				set value [ini::value $ini $section $key]
				set bridge($key) $value
			}
		}
	}
	ini::close $ini
	if {![info exists bridge(key)]} {
		set bridge(key) ""
	}
	release_lock $lock_id_ini_file
	return [array get bridge]
}

proc ::hue::delete_bridge {bridge_id} {
	variable ini_file
	variable lock_id_ini_file
	acquire_lock $lock_id_ini_file
	set bridge_id [string tolower $bridge_id]
	set ini [ini::open $ini_file r+]
	ini::delete $ini "bridge_${bridge_id}"
	ini::commit $ini
	release_lock $lock_id_ini_file
}

proc ::hue::timeout_socket {ip port timeout} {
	global connected
	after $timeout { set connected "timeout" }
	set sock [socket -async $ip $port]
	fileevent $sock w { set connected "ok" }
	vwait connected
	if {$connected == "timeout"} {
		error "connection timed out after ${timeout} milliseconds"
	} else {
		return $sock
	}
}

proc ::hue::_http_request {ip port method path {data ""} {content_type ""} {timeout 0}} {
	set sock ""
	if {$timeout > 0} {
		set sock [timeout_socket $ip $port $timeout]
	} else {
		set sock [socket $ip $port]
	}
	puts $sock "${method} ${path} HTTP/1.1"
	puts $sock "Host: ${ip}:${port}"
	puts $sock "User-Agent: cuxd"
	if {$content_type != ""} {
		puts $sock "Content-Type: ${content_type}"
	}
	if {$data != ""} {
		puts $sock "Content-Length: [string length $data]"
	}
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
	if {$response == ""} {
		error "Failed to connect to server at address $ip"
	}
	catch { close $sock }
	return $response
}

proc ::hue::http_request {ip port method path {data ""} {content_type ""} {timeout 0}} {
	set response ""
	set trynum 0
	while {1} {
		incr trynum
		if { [catch {
			set response [_http_request $ip $port $method $path $data $content_type $timeout]
		} errmsg] } {
			write_log 2 "HTTP request failed (trynum ${trynum}): ${errmsg} - ${::errorCode}"
			if {[string first "connection timed out" $errmsg] == -1} {
				error $errmsg $::errorInfo
			}
			if {$trynum >= 3} {
				error $errmsg $::errorInfo
			}
		} else {
			if {$trynum > 1} {
				write_log 3 "HTTP request succeeded on trynum ${trynum}"
			}
			return $response
		}
	}
}

proc ::hue::api_request {type ip port username method path {data ""}} {
	variable api_log
	variable api_connect_timeout
	if {[string first "/" $path] == 0} {
		set path [string range $path 1 end]
	}
	set path "/api/${username}/${path}"
	set log 0
	if {$api_log == "all" || $type == $api_log} {
		set log 1
	}
	if {$log} {
		write_log 0 "api request: ${ip} - ${method} - ${path} - ${data}"
	}
	set res [http_request $ip $port $method $path $data "application/json" $api_connect_timeout]
	if {$log} {
		hue::write_log 0 "api response: ${res}"
	}
	return $res
}

proc ::hue::api_establish_link {ip port} {
	set response [http_request $ip $port "POST" "/api" "\{\"devicetype\":\"${hue::devicetype}\"\}" "application/json"]
	regexp {"success":.*"username"\s*:\s*"([a-zA-Z0-9\-]+)"} $response match username
	if {[info exists username]} {
		return $username
	}
	error $response
}

proc ::hue::request {type bridge_id method path {data ""}} {
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
	#acquire_bridge_lock $bridge_id
	set res [api_request $type $bridge(ip) $bridge(port) $bridge(username) $method $path $data]
	#release_bridge_lock $bridge_id
	return $res
}

proc ::hue::hue_command {bridge_id command args} {
	#error "${command} >${args}<" "Debug" 500
	set res [eval $command [list $bridge_id] [lrange $args 0 end]]
	return $res
}

proc ::hue::get_scene_name_id_map {bridge_id} {
	array set scenes {}
	set data [hue::request "info" $bridge_id "GET" "scenes"]
	while {1} {
		if {[regexp {\"([a-zA-Z0-9\-]{15})\":\{.*?\"name\":\"([^\"]+)\"(.*)$} $data match id name data]} {
			set scenes($name) $id
		} else {
			break
		}
	}
	return [array get scenes]
}

proc ::hue::get_cuxd_channels_min_max {device} {
	variable cuxd_xmlrpc_url
	if {[regexp {CUxD\.(\S+)} $device match addr]} {
		set device $addr
	}
	set ct_min 153
	set bri_min 0
	set hue_min 0
	set sat_min 0
	set command [lindex [xmlrpc $cuxd_xmlrpc_url getParamset [list string $device] [list string "MASTER"]] 3]
	if {[regexp {ct_min:(\d+)} $command match val]} {
		set ct_min [expr {0 + $val}]
	} else {
	hue::write_log 4 "device ${device} - ct_min not found in command, using default: ${ct_min}"
	}
	set bri_max [expr {0 + [lindex [xmlrpc $cuxd_xmlrpc_url getParamset [list string $device:2] [list string "MASTER"]] 3]}]
	set ct_max [expr {$ct_min + [lindex [xmlrpc $cuxd_xmlrpc_url getParamset [list string $device:3] [list string "MASTER"]] 3]}]
	set hue_max [lindex [xmlrpc $cuxd_xmlrpc_url getParamset [list string $device:4] [list string "MASTER"]] 3]
	if {$hue_max == ""} {
		set hue_max 0
	} else {
		set hue_max [expr {0 + $hue_max}]
	}
	set sat_max [lindex [xmlrpc $cuxd_xmlrpc_url getParamset [list string $device:5] [list string "MASTER"]] 3]
	if {$sat_max == ""} {
		set sat_max 0
	} else {
		set sat_max [expr {0 + $sat_max}]
	}
	return [list $bri_min $bri_max $ct_min $ct_max $hue_min $hue_max $sat_min $sat_max]
}

proc ::hue::get_cuxd_device_map_cuxd_ps {} {
	variable cuxd_ps
	variable dmap
	set fp [open $cuxd_ps r]
	fconfigure $fp -buffering line
	gets $fp data
	set device ""
	set channel ""
	while {$data != ""} {
		if { [string first " " $data] != 0 } {
			set device ""
			if { [string first "28 01" $data] == 0 || [string first "28 02" $data] == 0 || [string first "40 00" $data] == 0 } {
				set device [string map {" " ""} $data]
				set device "CUX${device}"
				hue::write_log 4 "get_cuxd_device_map: device=${device}"
			}
		} elseif {$device != ""} {
			set data [string tolower $data]
			if {[regexp "cmd\[sh\]? (\\d*)\\D.*hue\\.tcl\\s+(\\S+)\\s+(light|group)\\s+(\\d+)" $data match channel bridge_id obj num]} {
				if {$channel != ""} {
					set channel ":${channel}"
				}
				set dmap(${device}${channel}) "${bridge_id}_${obj}_${num}"
				hue::write_log 4 "get_cuxd_device_map: device=${device}${channel} mapped=${bridge_id}_${obj}_${num}"
			}
		}
		gets $fp data
	}
	close $fp
	return [array get dmap]
}

proc ::hue::get_cuxd_device_map {} {
	variable cuxd_xmlrpc_url
	variable dmap
	
	set devices [xmlrpc $cuxd_xmlrpc_url listDevices]
	foreach device $devices {
		set address [lindex $device 1]
		if {[regexp {^CUX(28|40)(00|01|02)(\d\d\d)} $address match dtype dtype2 serial]} {
			set paramset [xmlrpc $cuxd_xmlrpc_url getParamset [list string $address] [list string "MASTER"]]
			if {$dtype == 28} {
				if {$dtype2 == 1} {
					set command [lindex $paramset 11]
				} else {
					set command [lindex $paramset 3]
				}
			} else {
				set command [lindex $paramset 5]
			}
			if {$command != ""} {
				if {[regexp ".*hue\\.tcl\\s+(\\S+)\\s+(light|group)\\s+(\\d+)" $command match bridge_id obj num]} {
					set dmap(${address}) "${bridge_id}_${obj}_${num}"
					hue::write_log 4 "get_cuxd_device_map: device=${address} mapped=${bridge_id}_${obj}_${num}"
				}
			}
		}
	}
	return [array get dmap]
}

proc ::hue::update_cuxd_device_channel {device channel reachable on} {
	variable ignore_unreachable
	hue::write_log 4 "update_device_channel ${device}:${channel}: reachable=${reachable} on=${on}"
	if {$reachable == "false" || $reachable == 0} {
		if {$ignore_unreachable} {
			hue::write_log 4 "ignoring unreachable device, no update"
			return
		}
	}
	
	if {$on == "false" || $on == 0} {
		set on 0
	} else {
		set on 1
	}
	if {$reachable == "false" || $reachable == 0} {
		set on 0
	}
	set s "dom.GetObject(\"${device}:${channel}.SET_STATE\").State(${on});"
	#hue::write_log 4 "rega_script ${s}"
	rega_script $s
}

proc ::hue::update_cuxd_device_channels {device reachable on bri ct hue sat} {
	variable ignore_unreachable
	hue::write_log 4 "update_device_channels ${device}: reachable=${reachable} on=${on} bri=${bri} ct=${ct} hue=${hue} sat=${sat}"
	if {$reachable == "false" || $reachable == 0} {
		if {$ignore_unreachable} {
			hue::write_log 4 "ignoring unreachable device, no update"
			return
		}
	}
	
	set mm [get_cuxd_channels_min_max $device]
	hue::write_log 4 "get_cuxd_channels_min_max: ${mm}"
	
	set bri [ format "%.2f" [expr {double($bri) / [lindex $mm 1]}] ]
	if {$bri > 1.0} { set bri 1.0 }
	
	set ct [ format "%.2f" [expr {double($ct - [lindex $mm 2]) / double([lindex $mm 3] - [lindex $mm 2])}] ]
	if {$ct > 1.0} { set ct 1.0 }
	
	if {[lindex $mm 5] > 0} {
		set hue [ format "%.2f" [expr {double($hue) / [lindex $mm 5]}] ]
		if {$hue > 1.0} { set hue 1.0 }
	} else {
		set hue 0.0
	}
	
	if {[lindex $mm 7] > 0} {
		set sat [ format "%.2f" [expr {double($sat) / [lindex $mm 7]}] ]
		if {$sat > 1.0} { set sat 1.0 }
	} else {
		set sat 0.0
	}
	
	if {$reachable == "false" || $reachable == 0} {
		set on 0
	}
	if {$on == "false" || $on == 0} {
		set bri 0.0
	} else {
		if {$bri == 0.0} {
			set bri 0.01
		}
	}
	hue::write_log 4 "update_device_channels ${device} set states: bri=${bri} ct=${ct} hue=${hue} sat=${sat}"
	set s "
		if (dom.GetObject(\"${device}:2.LEVEL\")) \{
			dom.GetObject(\"${device}:2.SET_STATE\").State(${bri});
		\}
		if (dom.GetObject(\"${device}:3.LEVEL\")) \{
			dom.GetObject(\"${device}:3.SET_STATE\").State(${ct});
		\}
		if (dom.GetObject(\"${device}:4.LEVEL\")) \{
			dom.GetObject(\"${device}:4.SET_STATE\").State(${hue});
		\}
		if (dom.GetObject(\"${device}:5.LEVEL\")) \{
			dom.GetObject(\"${device}:5.SET_STATE\").State(${sat});
		\}
	"
	
	#hue::write_log 4 "rega_script ${s}"
	rega_script $s
}

proc ::hue::get_object_state {bridge_id obj_path} {
	set calc_group_brightness 1
	set data [request "status" $bridge_id "GET" $obj_path]
	#hue::write_log 4 "${obj_path}: ${data}"
	set st [list]
	regexp {\"reachable\"\s*:\s*(true|false)} $data match val
	if { [info exists val] && $val != "" } {
		lappend st $val
		unset val
	} else {
		regexp {\"error\"(.*)} $data match val
		if { [info exists val] && $val != "" } {
			lappend st "false"
			unset val
		} else {
			lappend st "true"
		}
	}
	regexp {\"any_on\"\s*:\s*(true|false)} $data match val
	if { [info exists val] && $val != "" } {
		lappend st $val
		unset val
	} else {
		regexp {\"on\"\s*:\s*(true|false)} $data match val
		if { [info exists val] && $val != "" } {
			lappend st $val
			unset val
		} else {
			lappend st "false"
		}
	}
	set val 0
	if {[regexp {^groups} $obj_path] && $calc_group_brightness} {
		#"lights":["11","10","9"]
		if [regexp {\"lights\"\s*:\s*\[(["\d,]+)\]} $data match lights] {
			#set lights [split $lights ","]
			set light_num 0
			set bri_sum 0
			set any_reachable 0
			foreach light [split $lights ","] {
				set light_num [expr {$light_num + 1}]
				set light [string map {"\"" ""} $light]
				set light_data [request "status" $bridge_id "GET" "lights/${light}"]
				#hue::write_log 4 "Light ${light}: ${ldata}"
				regexp {\"bri\"\s*:\s*(\d+)} $light_data match bri
				set bri_sum [expr {$bri_sum + $bri}]
				if {$any_reachable == 0} {
					if {[regexp {\"reachable\"\s*:\s*(true|false)} $light_data match reachable]} {
						if {$reachable == "true"} {
							set any_reachable 1
						}
					}
				}
			}
			set val [expr {$bri_sum / $light_num}]
			if {$any_reachable == 0} {
				set st [lreplace $st 0 0 "false"]
			} else {
				set st [lreplace $st 0 0 "true"]
			}
			hue::write_log 4 "Calculated group reachable: ${any_reachable}, brightness: ${val}"
		}
	} else {
		regexp {\"bri\"\s*:\s*(\d+)} $data match val
	}
	lappend st [expr {0 + $val}]
	regexp {\"ct\"\s*:\s*(\d+)} $data match val
	lappend st [expr {0 + $val}]
	regexp {\"hue\"\s*:\s*(\d+)} $data match val
	lappend st [expr {0 + $val}]
	regexp {\"sat\"\s*:\s*(\d+)} $data match val
	lappend st [expr {0 + $val}]
	return $st
}


proc ::hue::get_used_cuxd_device_serials {dtype {dtype2 0}} {
	set type "CUX[format %02s $dtype]"
	if {$dtype2 > 0} {
		set type "CUX[format %02s $dtype][format %02s $dtype2]"
	}
	set s "
		string type = '${type}';
		string deviceid;
		foreach(deviceid, dom.GetObject(ID_DEVICES).EnumUsedIDs()) {
			var device = dom.GetObject(deviceid);
			if (device && device.Address().StartsWith(type)) {
				integer serial = 0 + device.Address().Substr(7,8);
				WriteLine(serial);
			}
		}
	"
	hue::write_log 4 "rega_script ${s}"
	array set res [rega_script $s]
	set serials [string trim [encoding convertfrom utf-8 $res(STDOUT)]]
	#if {$free_serial >= 1000} {
	#	error "No free serial found"
	#}
	#return [expr {0 + $free_serial}]
	#puts [split $serials "\r\n"]
	set serials [split [string map {"\r" ""} $serials] "\n"]
	set serials [lsort -integer $serials]
	return $serials
}

proc ::hue::get_free_cuxd_device_serial {dtype {dtype2 0}} {
	set serials [get_used_cuxd_device_serials $dtype $dtype2]
	set max_serial [lindex $serials end]
	if {$max_serial == ""} {
		set max_serial 0
	}
	return [expr {$max_serial + 1}]
}

proc ::hue::urlencode {string} {
	variable map
	variable alphanumeric a-zA-Z0-9
	for {set i 0} {$i <= 256} {incr i} {
		set c [format %c $i]
		if {![string match \[$alphanumeric\] $c]} {
			set map($c) %[format %.2x $i]
		}
	}
	array set map { " " + \n %0d%0a }
	regsub -all \[^$alphanumeric\] $string {$map(&)} string
	regsub -all {[][{})\\]\)} $string {\\&} string
	return [subst -nocommand $string]
}


proc ::hue::create_cuxd_switch_device {sid serial name bridge_id obj num} {
	variable cuxd_xmlrpc_url
	set dtype 40
	
	if {$serial <= 0} {
		set serial [get_free_cuxd_device_serial $dtype 0]
	}
	set serial [expr {0 + $serial}]
	
	set dbase 10022
	set response [http_request "127.0.0.1" 80 "GET" "/addons/cuxd/index.ccc?sid=@${sid}@&m=2${dtype}&dtype2=0"]
	if {[regexp {option\s+(selected)?\s*value\D+(\d+)\D+Fernbedienung 19 Tasten} $response match tmp value]} {
		set dbase $value
	}
	
	set device "CUX[format %02s $dtype][format %05s $serial]"
	set command_short "/usr/local/addons/hue/hue.tcl ${bridge_id} ${obj} ${num} on:false"
	set command_long "/usr/local/addons/hue/hue.tcl ${bridge_id} ${obj} ${num} on:true"
	#set data "dtype=${dtype}&dserial=${serial}&dname=[urlencode $name]&dbase=${dbase}&dcontrol=1"
	set data "dtype=${dtype}&dserial=${serial}&dbase=${dbase}&dcontrol=1"
	
	hue::write_log 4 "Creating cuxd switch device with serial ${serial}"
	set response [http_request "127.0.0.1" 80 "POST" "/addons/cuxd/index.ccc?sid=@${sid}@&m=3" $data "application/x-www-form-urlencoded"]
	hue::write_log 4 "CUxD response: ${response}"
	
	set i 0
	while {$i < 10} {
		set serials [get_used_cuxd_device_serials $dtype 0]
		if {[lsearch -exact $serials $serial] >= 0} {
			hue::write_log 4 "Device with serial ${serial} found"
			break
		}
		after 1000
		incr i
	}
	
	set struct [list [list "CMD_EXEC" [list "bool" 1]] [list "CMD_SHORT" [list "string" $command_short]] [list "CMD_LONG" [list "string" $command_long]]]
	xmlrpc $cuxd_xmlrpc_url putParamset [list string "${device}:1"] [list string "MASTER"] [list struct $struct]
	
	after 5000
	
	set ch1 [encoding convertfrom identity [string map {. ,} "${name}"]]
	
	set s "
		object devices = dom.GetObject(ID_DEVICES);
		if (devices) {
			string id = '';
			foreach(id, devices.EnumEnabledIDs()) {
				object device = dom.GetObject(id);
				if (device && (device.Address() == '${device}')) {
					string channelId;
					foreach(channelId, device.Channels()) {
						object channel = dom.GetObject(channelId);
						if (channel.ChnNumber() == 1) {
							channel.Name('${ch1}');
							WriteLine(channel.Name());
						}
					}
				}
			}
		}
	"
	hue::write_log 4 "rega_script ${s}"
	array set res [rega_script $s]
	set stdout [encoding convertfrom utf-8 $res(STDOUT)]
	hue::write_log 4 "${stdout}"
	
	return $device
}

proc ::hue::create_cuxd_dimmer_device {sid serial name bridge_id obj num ct_min ct_max {color 0}} {
	variable cuxd_xmlrpc_url
	set dtype 28
	set dtype2 2
	
	if {$serial <= 0} {
		set serial [get_free_cuxd_device_serial $dtype $dtype2]
	}
	set serial [expr {0 + $serial}]
	
	set dbase 10042
	set response [http_request "127.0.0.1" 80 "GET" "/addons/cuxd/index.ccc?sid=@${sid}@&m=2${dtype}&dtype2=${dtype2}"]
	if {[regexp {option\s+(selected)?\s*value\D+(\d+)\D+Dimmaktor 1fach Unterputz} $response match tmp value]} {
		set dbase $value
	}
	
	set device "CUX[format %02s $dtype][format %02s $dtype2][format %03s $serial]"
	set command "/usr/local/addons/hue/hue.tcl ${bridge_id} ${obj} ${num} ct_min:${ct_min} transitiontime:0"
	set data "dtype=${dtype}&dtype2=${dtype2}&dserial=${serial}&dname=[urlencode $name]&dbase=${dbase}"
	
	hue::write_log 4 "Creating cuxd dimmer device with serial ${serial}"
	set response [http_request "127.0.0.1" 80 "POST" "/addons/cuxd/index.ccc?sid=@${sid}@&m=3" $data "application/x-www-form-urlencoded"]
	hue::write_log 4 "CUxD response: ${response}"
	
	set i 0
	while {$i < 10} {
		set serials [get_used_cuxd_device_serials $dtype $dtype2]
		if {[lsearch -exact $serials $serial] >= 0} {
			hue::write_log 4 "Device with serial ${serial} found"
			break
		}
		after 1000
		incr i
	}
	
	set channels 2
	if {$color} {
		set channels 4
	}
	
	set struct [list [list "CHANNELS" [list "int" $channels]] [list "CMD_EXEC" [list "string" $command]] [list "SYSLOG" [list "bool" 0]] ]
	xmlrpc $cuxd_xmlrpc_url putParamset [list string $device] [list string "MASTER"] [list struct $struct]
	
	set struct [list [list "EXEC_ON_CHANGE" [list "bool" 1]] [list "MAX_VAL" [list "int" 254]]]
	xmlrpc $cuxd_xmlrpc_url putParamset [list string "${device}:2"] [list string "MASTER"] [list struct $struct]
	set struct [list [list "EXEC_ON_CHANGE" [list "bool" 1]] [list "MAX_VAL" [list "int" [expr {$ct_max - $ct_min}]]]]
	xmlrpc $cuxd_xmlrpc_url putParamset [list string "${device}:3"] [list string "MASTER"] [list struct $struct]
	if {$channels == 4} {
		set struct [list [list "EXEC_ON_CHANGE" [list "bool" 1]] [list "MAX_VAL" [list "int" 65535]]]
		xmlrpc $cuxd_xmlrpc_url putParamset [list string "${device}:4"] [list string "MASTER"] [list struct $struct]
		set struct [list [list "EXEC_ON_CHANGE" [list "bool" 1]] [list "MAX_VAL" [list "int" 254]]]
		xmlrpc $cuxd_xmlrpc_url putParamset [list string "${device}:5"] [list string "MASTER"] [list struct $struct]
	}
	#puts [xmlrpc $cuxd_xmlrpc_url getParamset [list string $address] [list string "MASTER"] ]
	#puts [xmlrpc $cuxd_xmlrpc_url getParamset [list string "${address}:2"] [list string "MASTER"] ]
	#puts [xmlrpc $cuxd_xmlrpc_url getParamset [list string "${address}:3"] [list string "MASTER"] ]
	#puts [xmlrpc $cuxd_xmlrpc_url getParamset [list string "${address}:4"] [list string "MASTER"] ]
	#puts [xmlrpc $cuxd_xmlrpc_url getParamset [list string "${address}:5"] [list string "MASTER"] ]
	
	after 5000
	
	# http://www.wikimatic.de/wiki/Kategorie:Methoden
	
	set ch1 [encoding convertfrom identity [string map {. ,} "${name} - Status aktualisieren"]]
	set ch2 [encoding convertfrom identity [string map {. ,} "${name} - Helligkeit"]]
	set ch3 [encoding convertfrom identity [string map {. ,} "${name} - Farbtemperatur"]]
	set ch4 [encoding convertfrom identity [string map {. ,} "${name} - Farbton"]]
	set ch5 [encoding convertfrom identity [string map {. ,} "${name} - Sättigung"]]
	
	set s "
		object devices = dom.GetObject(ID_DEVICES);
		if (devices) {
			string id = '';
			foreach(id, devices.EnumEnabledIDs()) {
				object device = dom.GetObject(id);
				if (device && (device.Address() == '${device}')) {
					string channelId;
					foreach(channelId, device.Channels()) {
						object channel = dom.GetObject(channelId);
						if ((channel.ChnNumber() >= 1) && (channel.ChnNumber() <= ${channels} + 1)) {
							if (channel.ChnNumber() == 1) {
								channel.Name('${ch1}');
							}
							elseif (channel.ChnNumber() == 2) {
								channel.Name('${ch2}');
							}
							elseif (channel.ChnNumber() == 3) {
								channel.Name('${ch3}');
							}
							elseif (channel.ChnNumber() == 4) {
								channel.Name('${ch4}');
							}
							elseif (channel.ChnNumber() == 5) {
								channel.Name('${ch5}');
							}
							WriteLine(channel.Name());
						}
					}
				}
			}
		}
	"
	hue::write_log 4 "rega_script ${s}"
	array set res [rega_script $s]
	set stdout [encoding convertfrom utf-8 $res(STDOUT)]
	hue::write_log 4 "${stdout}"
	
	return $device
	
	set s "
		object devices = dom.GetObject(ID_DEVICES);
		if (devices) {
			string id = '';
			foreach(id, devices.EnumEnabledIDs()) {
				object device = dom.GetObject(id);
				if (device && (device.Address() == '${device}') && (device.ReadyConfig() == false)) {
					var devId = id;
					Call('devices.fn::setReadyConfig()');
					WriteLine(id);
				}
			}
		}
	"
	##hue::write_log 4 "rega_script ${s}"
	array set res [rega_script $s]
	set device_id [string trim [encoding convertfrom utf-8 $res(STDOUT)]]
	#puts $device_id
	
	return $device
	
	set s "
		object devices = dom.GetObject(ID_DEVICES);
		if (devices) {
			string id = '';
			foreach(id, devices.EnumEnabledIDs()) {
				object device = dom.GetObject(id);
				if (device && (device.Address() == '${device}') && (device.ReadyConfig() == false)) {
					string channelId;
					foreach(channelId, device.Channels()) {
						object channel = dom.GetObject(channelId);
						channel.ReadyConfig(true);
					}
					device.ReadyConfig(true, false);
					WriteLine(id);
				}
			}
		}
	"
	##hue::write_log 4 "rega_script ${s}"
	array set res [rega_script $s]
	set device_id [string trim [encoding convertfrom utf-8 $res(STDOUT)]]
	#puts $device_id
	
	return $device
}

proc ::hue::delete_cuxd_device {id} {
	set data "dselect=${id}"
	set response [http_request "127.0.0.1" 80 "POST" "/addons/cuxd/index.ccc?m=4" $data "application/x-www-form-urlencoded"]
	puts $response
}

hue::read_global_config

#hue::get_used_cuxd_device_serials 28 2
#puts [hue::get_free_cuxd_device_serial 40]
#hue::create_cuxd_switch_device 0 "test" "xxxxxxxxx" "light" 15
#puts [hue::create_cuxd_switch_device "7vfpOdgtD0" 0 "test" "xxxxxxxxx" "light" 15]
#puts [hue::create_cuxd_dimmer_device "7vfpOdgtD0" 20 "test" "xxxxxxxxx" "light" 15 0 255]
#hue::delete_cuxd_device "2802010"
#puts [hue::get_cuxd_channels_min_max "CUX2802003"]
#puts [hue::request "" "PUT" "lights/1/state" "\{\"on\":true,\"sat\":254,\"bri\":254,\"hue\":1000\}"]
#puts [hue::request "" "PUT" "lights/2/state" "\{\"on\":true,\"sat\":254,\"bri\":254,\"hue\":1000\}"]
#puts [hue::request "" "PUT" "lights/1/state" "\{\"alert\":\"select\"\}"]
#puts [hue::request "" "PUT" "lights/2/state" "\{\"alert\":\"select\"\}"]
#puts [hue::request "" "PUT" "lights/1/state" "\{\"effect\":\"colorloop\"\}"]
#puts [hue::request "" "PUT" "lights/2/state" "\{\"effect\":\"colorloop\"\}"]
#puts [hue::request "" "PUT" "lights/1/state" "\{\"effect\":\"none\"\}"]
#puts [hue::request "" "PUT" "lights/2/state" "\{\"effect\":\"none\"\}"]
#puts [hue::request "" "GET" "groups"]
#puts [hue::request "" "GET" "groups/1"]
#puts [hue::request "" "PUT" "groups/1/action" "\{\"on\":true\}"]
#puts [hue::request "" "GET" "config"]
#puts [hue::request "" "GET" "scenes"]
#puts [hue::request "" "PUT" "groups/1/action" "\{\"scene\":\"jXTvbsXs9KO8PVw\"\}"]
#puts [hue::get_cuxd_device_map]
#puts [hue::get_scene_name_id_map "xxxxxxxxxxxxxxxxxx"]
