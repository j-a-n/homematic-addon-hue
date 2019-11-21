#!/bin/tclsh

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

load tclrega.so
source /usr/local/addons/hue/lib/hue.tcl
package require http

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

proc get_http_header {request header_name} {
	upvar $request req
	set header_name [string toupper $header_name]
	array set meta $req(meta)
	foreach header [array names meta] {
		if {$header_name == [string toupper $header] } then {
			return $meta($header)
		}
	}
	return ""
}

proc get_session {sid} {
	if {[regexp {@([0-9a-zA-Z]{10})@} $sid match sidnr]} {
		return [lindex [rega_script "Write(system.GetSessionVarStr('$sidnr'));"] 1]
	}
	return ""
}

proc check_session {sid} {
	if {[get_session $sid] != ""} {
		# renew session
		set url "http://127.0.0.1/pages/index.htm?sid=$sid"
		set request [::http::geturl $url]
		set code [::http::code $request]
		::http::cleanup $request
		if {[lindex $code 1] == 200} {
			return 1
		}
		return 1
	}
	return 0
}

proc login {username password} {
	set request [::http::geturl "http://127.0.0.1/login.htm" -query [::http::formatQuery tbUsername $username tbPassword $password]]
	set code [::http::code $request]
	set location [get_http_header $request "location"]
	::http::cleanup $request
	
	if {[string first "error" $location] != -1} {
		error "Invalid username oder password" "Unauthorized" 401
	}
	
	if {![regexp {sid=@([0-9a-zA-Z]{10})@} $location match sid]} {
		error "Too many sessions" "Service Unavailable" 503
	}
	return $sid
}

proc process {} {
	global env
	if { [info exists env(QUERY_STRING)] } {
		set query $env(QUERY_STRING)
		set sid ""
		set pairs [split $query "&"]
		foreach pair $pairs {
			if {[regexp "^(\[^=\]+)=(.*)$" $pair match varname value]} {
				if {$varname == "sid"} {
					set sid $value
				} elseif {$varname == "path"} {
					set path [split $value "/"]
				}
			}
		}
		set plen [expr [llength $path] - 1]
		
		
		if {[lindex $path 1] == "login"} {
			set data [read stdin $env(CONTENT_LENGTH)]
			regexp {\"username\"\s*:\s*\"([^\"]*)\"} $data match username
			regexp {\"password\"\s*:\s*\"([^\"]*)\"} $data match password
			set sid [login $username $password]
			return "\"${sid}\""
		}
		
		if {![check_session $sid]} {
			error "Invalid session" "Unauthorized" 401
		}
		
		set data ""
		if { [info exists env(CONTENT_LENGTH)] } {
			set data [read stdin $env(CONTENT_LENGTH)]
		}
		
		if {[lindex $path 1] == "get_session"} {
			return "\"[get_session $sid]\""
		} elseif {[lindex $path 1] == "version"} {
			return "\"[hue::version]\""
		} elseif {[lindex $path 1] == "test-command"} {
			regexp {\"command\"\s*:\s*\"(.*)\"} $data match command
			set exitcode 0
			set output ""
			if {! [regexp {^/usr/local/addons/hue/hue.tcl( |$)[a-zA-Z0-9 \"'\-:_/]*$} $command] } {
				set exitcode 1
				set output "Invalid command: ${command}"
			} else {
				set exitcode [catch {
					regexp {\"language\"\s*:\s*\"([^\"]+)\"} $data match language
					set ::env(LANGUAGE) $language
					eval exec $command
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
			regexp {\"name\"\s*:\s*\"([^\"]+)\"} $config match name
			regexp {\"bridgeid\"\s*:\s*\"([^\"]+)\"} $config match bridgeid
			hue::api_request "command" $ip 80 $username "PUT" "groups/0/action" "\{\"alert\":\"select\"\}"
			set username [json_string $username]
			set name [json_string $name]
			set bridgeid [json_string $bridgeid]
			return "\{\"username\":\"${username}\",\"name\":\"${name}\"\,\"bridgeid\":\"${bridgeid}\"\}"
		} elseif {[lindex $path 1] == "get-cuxd-device-map"} {
			set dmap ""
			array set cuxd_device_map [hue::get_cuxd_device_map]
			foreach { cuxd_device o } [array get cuxd_device_map] {
				set tmp [split $o "_"]
				set bridge_id [lindex $tmp 0]
				set type [lindex $tmp 1]
				set id [lindex $tmp 2]
				if {$dmap != ""} {
					set dmap "${dmap},"
				}
				set dmap "${dmap}\{\"bridge_id\":\"${bridge_id}\",\"type\":\"${type}\",\"id\":\"${id}\",\"cuxd_device\":\"${cuxd_device}\"\}"
			}
			return "\[${dmap}\]"
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
			set res [hue::create_cuxd_dimmer_device $sid $serial $name $bridge_id $obj $num $ct_min $ct_max $color]
			hue::hued_command "reload"
			return "\"${res}\""
		} elseif {[lindex $path 1] == "create-cuxd-switch-device"} {
			regexp {\"serial\"\s*:\s*(\d+)} $data match serial
			regexp {\"name\"\s*:\s*\"([^\"]+)\"} $data match name
			regexp {\"bridge_id\"\s*:\s*\"([^\"]+)\"} $data match bridge_id
			regexp {\"obj\"\s*:\s*\"([^\"]+)\"} $data match obj
			regexp {\"num\"\s*:\s*(\d+)} $data match num
			set res [hue::create_cuxd_switch_device $sid $serial $name $bridge_id $obj $num]
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
					regexp {\"api_connect_timeout\"\s*:\s*\"([^\"]+)\"} $data match api_connect_timeout
					regexp {\"poll_state_interval\"\s*:\s*\"([^\"]+)\"} $data match poll_state_interval
					regexp {\"ignore_unreachable\"\s*:\s*(false|true)} $data match ignore_unreachable
					hue::update_global_config $log_level $api_log $poll_state_interval $ignore_unreachable $api_connect_timeout
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
				if {$pid == ""} {
					catch {
						set pid [exec pidof -x hued.tcl]
					}
				}
				return "\"${pid}\""
			} elseif {[lindex $path 2] == "restart"} {
				exec /usr/local/addons/hue/hued.tcl
				after 500
				return "\"OK\""
			}
		} elseif {[lindex $path 1] == "truncate-log"} {
			hue::truncate_log
			return "\"OK\""
		}
	}
	error "invalid request" "Not found" 404
}

if [catch {process} result] {
	set status 500
	if { $errorCode != "NONE" } {
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
