#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2018  Jan Schneider <oss@janschneider.net>
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

source /usr/local/addons/hue/lib/ini.tcl

namespace eval hue {
	variable version_file "/usr/local/addons/hue/VERSION"
	variable ini_file "/usr/local/addons/hue/etc/hue.conf"
	variable log_file "/tmp/hue-addon-log.txt"
	variable log_level 0
	variable lock_start_port 11200
	variable lock_socket
	variable lock_id_log_file 1
	variable lock_id_ini_file 2
	variable lock_id_bridge_start 3
	variable poll_state_interval 0
	variable ignore_unreachable 0
	variable devicetype "homematic-addon-hue#ccu"
	variable curl "/usr/local/addons/cuxd/curl"
	variable cuxd_ps "/usr/local/addons/cuxd/cuxd.ps"
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
	set fp [open $log_file r]
	set data [read $fp]
	close $fp
	return $data
}

proc ::hue::version {} {
	variable version_file
	set fp [open $version_file r]
	set data [read $fp]
	close $fp
	return [string trim $data]
}

proc ::hue::acquire_lock {lock_id} {
	variable lock_socket
	variable lock_start_port
	set port [expr { $lock_start_port + $lock_id }]
	set tn 0
	# 'socket already in use' error will be our lock detection mechanism
	while {1} {
		set tn [expr {$tn + 1}]
		if { [catch {socket -server dummy_accept $port} sock] } {
			if {$tn > 10} {
				write_log 1 "Failed to acquire lock ${lock_id} after 2500ms, ignoring lock" 0
				break
			}
			after 25
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

proc ::hue::update_global_config {log_level poll_state_interval ignore_unreachable} {
	variable ini_file
	variable lock_id_ini_file
	write_log 4 "Updating global config: log_level=${log_level} poll_state_interval=${poll_state_interval}"
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r+]
	ini::set $ini "global" "log_level" $log_level
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
	variable poll_state_interval
	variable ignore_unreachable
	write_log 4 "Reading global config"
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r]
	catch {
		set log_level [expr { 0 + [::ini::value $ini "global" "log_level" $log_level] }]
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
	variable poll_state_interval
	variable ignore_unreachable
	set iu "false"
	if {$ignore_unreachable} {
		set iu "true"
	}
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r]
	set json "\{\"global\":\{\"log_level\":${log_level},\"poll_state_interval\":${poll_state_interval},\"ignore_unreachable\":${iu}\},\"bridges\":\["
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
	if {$response == ""} {
		error "Failed to connect to hue bridge at address $ip"
	}
	catch { close $sock }
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

proc ::hue::get_scene_name_id_map {bridge_id} {
	array set scenes {}
	set data [hue::request $bridge_id "GET" "scenes"]
	while {1} {
		if {[regexp {\"([a-zA-Z0-9\-]{15})\":\{.*?\"name\":\"([^\"]+)\"(.*)$} $data match id name data]} {
			set scenes($name) $id
		} else {
			break
		}
	}
	return [array get scenes]
}

proc ::hue::get_cuxd_channels_max {device} {
	variable cuxd_ps
	set result {254 347 65535 254 255 255 255 255 255 255 255 255 255 255 255 255}
	regexp "^.*CUX(\\d\\d)(\\d+)$" $device match typenum devnum
	if { [info exists match] } {
		set fp [open $cuxd_ps r]
		fconfigure $fp -buffering line
		gets $fp data
		set dev_seen 0
		while {$data != ""} {
			if {$data == "${typenum} ${devnum}"} {
				set dev_seen 1
			} elseif {$dev_seen == 1} {
				if {[string first " MAX" $data] != -1} {
					set tmp [split $data " "]
					set i 0
					hue::write_log 4 "${device}: ${tmp}"
					foreach val [lrange $tmp 2 17] {
						set result [linsert $result $i [expr {0 + $val}]]
						set i [expr {$i+1}]
					}
					break
				}
			}
			gets $fp data
		}
		close $fp
	}
	return $result
}

proc ::hue::get_cuxd_device_map {} {
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
	
	set max [get_cuxd_channels_max $device]
	hue::write_log 4 "get_cuxd_channels_max: ${max}"
	
	set bri [ format "%.2f" [expr {double($bri) / [lindex $max 0]}] ]
	if {$bri > 1.0} { set bri 1.0 }
	set ct  [ format "%.2f" [expr {double($ct - 153) / [lindex $max 1]}] ]
	if {$ct > 1.0} { set ct 1.0 }
	set hue [ format "%.2f" [expr {double($hue) / [lindex $max 2]}] ]
	if {$hue > 1.0} { set hue 1.0 }
	set sat [ format "%.2f" [expr {double($sat) / [lindex $max 3]}] ]
	if {$sat > 1.0} { set sat 1.0 }
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
	set data [request $bridge_id "GET" $obj_path]
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
			foreach light [split $lights ","] {
				set light_num [expr {$light_num + 1}]
				set light [string map {"\"" ""} $light]
				set light_data [request $bridge_id "GET" "lights/${light}"]
				#hue::write_log 4 "Light ${light}: ${ldata}"
				regexp {\"bri\"\s*:\s*(\d+)} $light_data match bri
				set bri_sum [expr {$bri_sum + $bri}]
			}
			set val [expr {$bri_sum / $light_num}]
			hue::write_log 4 "Calculated group brightness: ${val}"
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

hue::read_global_config

#hue::api_register
#puts [hue::request "PUT" "lights/1/state" "\{\"on\":true,\"sat\":254,\"bri\":254,\"hue\":1000\}"]
#puts [hue::request "PUT" "lights/2/state" "\{\"on\":true,\"sat\":254,\"bri\":254,\"hue\":1000\}"]
#puts [hue::request "PUT" "lights/1/state" "\{\"alert\":\"select\"\}"]
#puts [hue::request "PUT" "lights/2/state" "\{\"alert\":\"select\"\}"]
#puts [hue::request "PUT" "lights/1/state" "\{\"effect\":\"colorloop\"\}"]
#puts [hue::request "PUT" "lights/2/state" "\{\"effect\":\"colorloop\"\}"]
#puts [hue::request "PUT" "lights/1/state" "\{\"effect\":\"none\"\}"]
#puts [hue::request "PUT" "lights/2/state" "\{\"effect\":\"none\"\}"]
#puts [hue::request "GET" "groups"]
#puts [hue::request "GET" "groups/1"]
#puts [hue::request "PUT" "groups/1/action" "\{\"on\":true\}"]
#puts [hue::request "GET" "config"]
#puts [hue::request "GET" "scenes"]
#puts [hue::request "PUT" "groups/1/action" "\{\"scene\":\"jXTvbsXs9KO8PVw\"\}"]
#puts [hue::get_cuxd_device_map]
#puts [hue::get_scene_name_id_map "xxxxxxxxxxxxxxxxxx"]
