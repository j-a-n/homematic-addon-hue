#!/bin/tclsh

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

source /usr/local/addons/hue/lib/hue.tcl

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

proc process {} {
	global env
	if { [info exists env(QUERY_STRING)] } {
		set query $env(QUERY_STRING)
		set data ""
		if { [info exists env(CONTENT_LENGTH)] } {
			set data [read stdin $env(CONTENT_LENGTH)]
		}
		set path [split $query {/}]
		set plen [expr [llength $path] - 1]
		
		if {[lindex $path 1] == "version"} {
			return "\"[hue::version]\""
		} elseif {[lindex $path 1] == "test-command"} {
			set exitcode 0
			set output ""
			if {! [regexp {^/usr/local/addons/hue/hue.tcl( |$)[a-zA-Z0-9 \-:_/]*$} $data] } {
				set exitcode 1
				set output "Invalid command"
			} else {
				set exitcode [catch {
					eval exec $data
				} output]
				set output [json_string $output]
			}
			return "\{\"exitcode\":${exitcode},\"output\":\"${output}\"\}"
		} elseif {[lindex $path 1] == "discover-bridges"} {
			set bridge_ips [hue::discover_bridges]
			set json "\["
			if {[llength $bridge_ips] > 0} {
				foreach b $bridge_ips {
					append json "\"${b}\","
				}
				set json [string range $json 0 end-1]
			}
			append json "\]"
			return $json
		} elseif {[lindex $path 1] == "establish-link"} {
			regexp {\"ip\"\s*:\s*\"([^\"]+)\"} $data match ip
			set username [hue::api_establish_link $ip 80]
			set config [hue::api_request "info" $ip 80 $username "GET" "config"]
			set config "\{\"username\":\"${username}\",[string range $config 1 end]"
			set data [hue::api_request "info" $ip 80 $username "GET" "lights"]
			foreach d [split $data "\}"] {
				set lid ""
				regexp {"(\d+)"\s*:\s*\{} $d match lid
				if { [info exists lid] && $lid != "" } {
					hue::api_request "command" $ip 80 $username "PUT" "lights/${lid}/state" "\{\"alert\":\"select\"\}"
				}
			}
			return $config
		} elseif {[lindex $path 1] == "get-used-cuxd-device-serials"} {
			regexp {\"dtype\"\s*:\s*(\d+)} $data match dtype
			set dtype2 0
			regexp {\"dtype2\"\s*:\s*(\d+)} $data match dtype2
			set serials [hue::get_used_cuxd_device_serials $dtype $dtype2]
			set res [join $serials ", "]
			return "\[${res}\]"
		} elseif {[lindex $path 1] == "create-cuxd-dimmer-device"} {
			regexp {\"serial\"\s*:\s*(\d+)} $data match serial
			regexp {\"name\"\s*:\s*\"([^\"]+)\"} $data match name
			regexp {\"bridge_id\"\s*:\s*\"([^\"]+)\"} $data match bridge_id
			regexp {\"obj\"\s*:\s*\"([^\"]+)\"} $data match obj
			regexp {\"num\"\s*:\s*(\d+)} $data match num
			regexp {\"ct_min\"\s*:\s*(\d+)} $data match ct_min
			regexp {\"ct_max\"\s*:\s*(\d+)} $data match ct_max
			regexp {\"color\"\s*:\s*(false|true)} $data match color
			if {$color == "true"} {
				set color 1
			} else {
				set color 0
			}
			set res [hue::create_cuxd_dimmer_device $serial $name $bridge_id $obj $num $ct_min $ct_max $color]
			hue::hued_command "reload"
			return "\"${res}\""
		} elseif {[lindex $path 1] == "create-cuxd-switch-device"} {
			regexp {\"serial\"\s*:\s*(\d+)} $data match serial
			regexp {\"name\"\s*:\s*\"([^\"]+)\"} $data match name
			regexp {\"bridge_id\"\s*:\s*\"([^\"]+)\"} $data match bridge_id
			regexp {\"obj\"\s*:\s*\"([^\"]+)\"} $data match obj
			regexp {\"num\"\s*:\s*(\d+)} $data match num
			set res [hue::create_cuxd_switch_device $serial $name $bridge_id $obj $num]
			hue::hued_command "reload"
			return "\"${res}\""
		} elseif {[lindex $path 1] == "config"} {
			if {$plen == 1} {
				if {$env(REQUEST_METHOD) == "GET"} {
					return [hue::get_config_json]
				}
			} elseif {[lindex $path 2] == "global"} {
				if {$env(REQUEST_METHOD) == "PUT"} {
					regexp {\"log_level\"\s*:\s*\"([^\"]+)\"} $data match log_level
					regexp {\"api_log\"\s*:\s*\"([^\"]+)\"} $data match api_log
					regexp {\"poll_state_interval\"\s*:\s*\"([^\"]+)\"} $data match poll_state_interval
					regexp {\"ignore_unreachable\"\s*:\s*(false|true)} $data match ignore_unreachable
					hue::update_global_config $log_level $api_log $poll_state_interval $ignore_unreachable
					hue::hued_command "reload"
					return "\"Global config successfully updated\""
				}
			} elseif {[lindex $path 2] == "bridge"} {
				if {$plen == 3} {
					if {$env(REQUEST_METHOD) == "PUT"} {
						set id [lindex $path 3]
						#error "${data}" "Debug" 500
						regexp {\"name\"\s*:\s*\"([^\"]+)\"} $data match name
						regexp {\"ip\"\s*:\s*\"([^\"]+)\"} $data match ip
						regexp {\"username\"\s*:\s*\"([^\"]+)\"} $data match username
						hue::create_bridge $id $name $ip $username
						return "\"Bridge ${id} successfully created\""
					} elseif {$env(REQUEST_METHOD) == "DELETE"} {
						set id [lindex $path 3]
						hue::delete_bridge $id
						return "\"Bridge ${id} successfully deleted\""
					}
				}
			}
		} elseif {[lindex $path 1] == "bridges"} {
			if {$plen == 3} {
				if {[lindex $path 3] == "request"} {
					set id [lindex $path 2]
					regexp {\"method\"\s*:\s*\"([^\"]+)\"} $data match method
					regexp {\"path\"\s*:\s*\"([^\"]+)\"} $data match path
					regexp {\"data\"\s*:\s*(.*)\}} $data match data
					if {$data == "null"} {
						set data ""
					}
					return [hue::request "command" $id $method $path $data]
				}
			}
		} elseif {[lindex $path 1] == "hued"} {
			if {[lindex $path 2] == "pid"} {
				set pid ""
				catch {
					set pid [exec pidof hued.tcl]
				}
				return "\"${pid}\""
			} elseif {[lindex $path 2] == "restart"} {
				exec /usr/local/addons/hue/hued.tcl
				after 500
				return "\"OK\""
			}
		}
	}
	error "invalid request" "Not found" 404
}

if [catch {process} result] {
	set status 500
	if { [info exists $errorCode] } {
		set status $errorCode
	}
	puts "Content-Type: application/json"
	puts "Status: $status";
	puts ""
	set result [json_string $result]
	puts -nonewline "\{\"error\":\"${result}\"\}"
} else {
	puts "Content-Type: application/json"
	puts "Status: 200 OK";
	puts ""
	puts -nonewline $result
}
