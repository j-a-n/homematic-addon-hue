#!/bin/tclsh

#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2020  Jan Schneider <oss@janschneider.net>
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

variable object_states
variable cuxd_device_map
variable group_command_times [list]
variable set_sysvars_reachable 1
variable scheduled_update_time 0
variable scheduled_update_cuxd_device_map_time 0
variable update_cuxd_device_map_interval 300

proc same_array {array1 array2} {
	array set a1 $array1
	array set a2 $array2
	
	foreach keys [list [array names a1] [array names a2]] {
		foreach key $keys {
			if {![info exists a1($key)]} {
				return 0
			}
			if {![info exists a2($key)]} {
				return 0
			}
			if {$a1($key) != $a2($key)} {
				return 0
			}
		}
	}
	return 1
}

proc bgerror message {
	hue::write_log 1 "Unhandled error: ${message}"
}

proc throttle_group_command {} {
	variable group_command_times
	
	set new [list]
	foreach t $group_command_times {
		set diff [expr {[clock seconds] - $t}]
		if {$diff < 10} {
			lappend new $t
		}
	}
	set group_command_times $new
	#hue::write_log 0 $group_command_times
	
	array set delay {}
	if { [catch {
		foreach s [split $hue::group_throttling_settings ","] {
			set tmp [split $s ":"]
			set n [expr {int([lindex $tmp 0])}]
			set d [expr {int([lindex $tmp 1])}]
			set delay($n) $d
		}
	} errmsg] } {
		hue::write_log 1 "Failed to set group throttling settings '${hue::group_throttling_settings}': ${errmsg}"
	}
	
	set ms 0
	set num [llength $group_command_times]
	foreach n [lsort -integer -decreasing [array names delay]] {
		if {$num >= $n} {
			set ms $delay($n)
			break
		}
	}
	if {$ms > 0} {
		hue::write_log 3 "Throttling group commands, waiting for ${ms} millis"
		after $ms
	}
	set group_command_times [linsert $group_command_times 0 [clock seconds]]
}

proc main_loop {} {
	if { [catch {
		check_update
	} errmsg] } {
		hue::write_log 1 "Error: ${errmsg} - ${::errorCode} - ${::errorInfo}"
		after 30000 main_loop
	} else {
		after 1000 main_loop
	}
}

proc update_cuxd_device_map {} {
	variable cuxd_device_map
	hue::write_log 4 "Updating cuxd device map"
	if { [catch {
		set dmap [hue::get_cuxd_device_map]
		array set cuxd_device_map $dmap
	} errmsg] } {
		hue::write_log 1 "Failed to get cuxd device map: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
}

proc get_cuxd_devices_from_map {bridge_id obj num} {
	variable cuxd_device_map
	set cuxd_devices [list]
	foreach { d o } [array get cuxd_device_map] {
		if { $o == "${bridge_id}_${obj}_${num}" } {
			lappend cuxd_devices $d
		}
	}
	return $cuxd_devices
}

proc get_bridge_ids_from_map {} {
	variable cuxd_device_map
	set bridge_ids [list]
	foreach { d o } [array get cuxd_device_map] {
		set bridge_id [lindex [split $o "_"] 0]
		if { [lsearch $bridge_ids $bridge_id] < 0 } {
			lappend bridge_ids $bridge_id
		}
	}
	return $bridge_ids
}


proc set_scheduled_update {time} {
	variable scheduled_update_time
	if {$scheduled_update_time <= 0 || $time < $scheduled_update_time} {
		set scheduled_update_time $time
	}
}

proc check_update {} {
	variable scheduled_update_time
	variable scheduled_update_cuxd_device_map_time
	variable update_cuxd_device_map_interval
	variable object_states
	
	hue::write_log 4 "Check update (scheduled_update_time=${scheduled_update_time})"
	
	if {[clock seconds] >= $scheduled_update_cuxd_device_map_time} {
		update_cuxd_device_map
		set scheduled_update_cuxd_device_map_time [expr {[clock seconds] + $update_cuxd_device_map_interval}]
	}
	
	if {$scheduled_update_time < 0 || [clock seconds] < $scheduled_update_time} {
		return
	}
	
	hue::write_log 4 "Updating status"
	
	foreach bridge_id [get_bridge_ids_from_map] {
		foreach obj_type [list "light" "group"] {
			set response [hue::request "status" $bridge_id "GET" "/${obj_type}s"]
			regsub -all {\n} $response "" response
			regsub -all {(\"\d+\":\{)} $response "\n\\1" tmp
			set tmp [split $tmp "\n"]
			foreach data $tmp {
				if {[regexp {\"(\d+)\":\{} $data match obj_id]} {
					set obj_path "/${obj_type}s/${obj_id}"
					set full_id "${bridge_id}_${obj_type}_${obj_id}"
					hue::write_log 4 "Processing status of ${obj_path}"
					array set state [hue::get_object_state_from_json $bridge_id $obj_type $obj_id $data [array get object_states]]
					
					if { [info exists object_states($full_id)] } {
						array set current_state $object_states($full_id)
						if {[same_array [array get state] [array get current_state]] == 1} {
							hue::write_log 4 "State of ${bridge_id} ${obj_type} ${obj_id} is unchanged"
							continue
						}
					}
					
					hue::write_log 4 "State of ${bridge_id} ${obj_type} ${obj_id} has changed"
					set object_states($full_id) [array get state]
					
					set cuxd_devices [get_cuxd_devices_from_map $bridge_id $obj_type $obj_id]
					if {[llength $cuxd_devices] == 0} {
						continue
					}
					foreach cuxd_device $cuxd_devices {
						update_cuxd_device $cuxd_device $bridge_id $obj_type $obj_id [array get state]
					}
				}
			}
		}
	}
	
	set_scheduled_update -1
	if {$hue::poll_state_interval > 0} {
		set_scheduled_update [expr {[clock seconds] + $hue::poll_state_interval}]
	}
}

proc update_sysvars_reachable {name reachable} {
	array set res [rega_script "var s = dom.GetObject(\"${name}\"); if (s) { Write(s.Value()); }"]
	set val ""
	if {$res(STDOUT) == "false"} {
		if {$reachable == 1 || $reachable == "true"} {
			set val "true"
		}
	} elseif {$res(STDOUT) == "true"} {
		if {$reachable == 0 || $reachable == "false"} {
			set val "false"
		}
	} else {
		hue::write_log 4 "Sysvar ${name} does not exist"
	}
	
	if {$val != ""} {
		hue::write_log 3 "Setting sysvar ${name} to ${val}"
		rega_script "dom.GetObject(\"${name}\").State(${val})"
	}
}

proc update_cuxd_device {cuxd_device bridge_id obj_type obj_id astate} {
	variable set_sysvars_reachable
	array set state $astate
	
	set channel ""
	if {[regexp "^(\[^:\]+):(\\d+)$" $cuxd_device match d c]} {
		hue::update_cuxd_device_channel "CUxD.$d" $c $state(reachable) $state(on)
	} else {
		hue::update_cuxd_device_channels "CUxD.$cuxd_device" $state(reachable) $state(on) $state(bri) $state(ct) $state(hue) $state(sat)
	}
	hue::write_log 3 "Update of ${bridge_id} ${obj_type} ${obj_id} / ${cuxd_device} successful (reachable=$state(reachable) on=$state(on) bri=$state(bri) ct=$state(ct) hue=$state(hue) sat=$state(sat))"
	if {$set_sysvars_reachable == 1} {
		update_sysvars_reachable "Hue_reachable_${cuxd_device}" $state(reachable)
		update_sysvars_reachable "Hue_reachable_${bridge_id}_${obj_type}_${obj_id}" $state(reachable)
	}
}

proc get_object_state {bridge_id obj_type obj_id} {
	variable object_states
	
	set full_id "${bridge_id}_${obj_type}_${obj_id}"
	if { ![info exists object_states($full_id)] } {
		set object_states($full_id) [hue::get_object_state $bridge_id $obj_type $obj_id]
	} elseif {$hue::poll_state_interval <= 0 || $hue::poll_state_interval > 10} {
		set object_states($full_id) [hue::get_object_state $bridge_id $obj_type $obj_id]
	}
	return $object_states($full_id)
}

proc read_from_channel {channel} {
	variable cuxd_device_map
	variable group_command_times
	variable scheduled_update_time
	variable object_states
	
	set len [gets $channel cmd]
	set cmd [string trim $cmd]
	hue::write_log 4 "Received command: $cmd"
	set response ""
	if { [catch {
		if {[regexp "^object_action\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s*(.*)$" $cmd match bridge_id obj_type obj_id params]} {
			set json "\{"
			foreach {name value} $params {
				append json "\"${name}\":${value},"
			}
			if {$json != "\{"} {
				set json [string range $json 0 end-1]
			}
			append json "\}"
			
			set path "lights/${obj_id}/state"
			if {$obj_type == "group"} {
				set path "groups/${obj_id}/action"
			}
			set response [hue::request "command" $bridge_id "PUT" $path $json]
		} elseif {[regexp "^object_state\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)$" $cmd match bridge_id obj_type obj_id]} {
			set full_id "${bridge_id}_${obj_type}_${obj_id}"
			set response ""
			if { [info exists object_states($full_id)] } {
				array set current_state $object_states($full_id)
				set response [array get current_state]
			}
		} elseif {[regexp "^update_object_state\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)$" $cmd match bridge_id obj_type obj_id]} {
			set_scheduled_update [clock seconds]
		} elseif {[regexp "^reload$" $cmd match]} {
			hue::read_global_config
			update_cuxd_device_map
			set_scheduled_update [clock seconds]
			set response "Reload scheduled"
		} elseif {[regexp "^status$" $cmd match]} {
			set response ""
			set tmp [clock seconds]
			append response "time: ${tmp}\n"
			append response "scheduled_update_time: ${scheduled_update_time}\n"
			set tmp [array get cuxd_device_map]
			set tmp [join $tmp " "]
			append response "cuxd_device_map: ${tmp}\n"
			set tmp [join $group_command_times " "]
			append response "group_command_times: ${tmp}\n"
		} else {
			set response "ERROR: Invalid command"
		}
	} errmsg] } {
		hue::write_log 1 "${errmsg} - ${::errorCode} - ${::errorInfo}"
		set response "ERROR: ${errmsg}"
	}
	hue::write_log 4 "Sending response: $response"
	puts $channel $response
	flush $channel
	close $channel
}

proc accept_connection {channel address port} {
	hue::write_log 4 "Accepted connection from $address\:$port"
	fconfigure $channel -blocking 0
	fconfigure $channel -buffersize 16
	fileevent $channel readable "read_from_channel $channel"
}

proc update_config {} {
	hue::write_log 3 "Update config $hue::ini_file"
	hue::acquire_lock $hue::lock_id_ini_file
	catch {
		set f [open $hue::ini_file r]
		set data [read $f]
		# Remove legacy options
		regsub -all {cuxd_device_[^\n]+\n} $data "" data
		close $f
		set f [open $hue::ini_file w]
		puts $f $data
		close $f
	}
	hue::release_lock $hue::lock_id_ini_file
}

proc main {} {
	variable hue::hued_address
	variable hue::hued_port
	variable cuxd_device_map
	if { [catch {
		update_config
	} errmsg] } {
		hue::write_log 1 "Error: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	
	main_loop
	
	if {$hue::hued_address == "0.0.0.0"} {
		socket -server accept_connection $hue::hued_port
	} else {
		socket -server accept_connection -myaddr $hue::hued_address $hue::hued_port
	}
	hue::write_log 3 "Hue daemon is listening for connections on ${hue::hued_address}:${hue::hued_port}"
}

if { "[lindex $argv 0 ]" != "daemon" && "[lindex $argv 0 ]" != "nofork" } {
	catch {
		foreach dpid [split [exec pidof [file tail $argv0]] " "] {
			if {[pid] != $dpid} {
				exec kill $dpid
			}
		}
	}
	if { "[lindex $argv 0 ]" != "stop" } {
		exec $argv0 daemon &
	}
} else {
	if { "[lindex $argv 0 ]" == "daemon" } {
		cd /
		foreach fd {stdin stdout stderr} {
			close $fd
		}
	} elseif { "[lindex $argv 0 ]" == "nofork" } {
		hue::set_log_stderr 4
	}
	main
	vwait forever
}
exit 0
