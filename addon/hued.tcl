#!/bin/tclsh

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

source /usr/local/addons/hue/lib/hue.tcl

variable update_schedule
variable current_object_state
variable cuxd_device_map
variable last_schedule_update 0
variable schedule_update_interval 60
variable group_command_times [list]

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
	
	set ms 0
	set num [llength $group_command_times]
	if {$num > 9} {
		# set ms 1700
		set ms 2000
	} elseif {$num > 4} {
		set ms 1000
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

proc check_update {} {
	variable update_schedule
	variable last_schedule_update
	variable schedule_update_interval
	variable cuxd_device_map
	
	foreach o [array names update_schedule] {
		set scheduled_time $update_schedule($o)
		#hue::write_log 4 "Update of ${o} cheduled for ${scheduled_time}"
		if {[clock seconds] >= $scheduled_time} {
			set tmp [split $o "_"]
			if {[catch {update_cuxd_device [lindex $tmp 0] [lindex $tmp 1] [lindex $tmp 2]} errmsg]} {
				hue::write_log 2 "Failed to update [lindex $tmp 0] [lindex $tmp 1] [lindex $tmp 2]: $errmsg - ${::errorCode} - ${::errorInfo}"
				# Device deleted? => refresh device map
				set last_schedule_update 0
				unset update_schedule($o)
			} else {
				if {$hue::poll_state_interval > 0} {
					set update_schedule($o) [expr {[clock seconds] + $hue::poll_state_interval}]
				} else {
					unset update_schedule($o)
				}
			}
		}
	}
	
	if { $hue::poll_state_interval > 0 && [clock seconds] >= [expr {$last_schedule_update + $schedule_update_interval}] } {
		hue::write_log 4 "Get device map and schedule update for all devices"
		set last_schedule_update [clock seconds]
		hue::read_global_config
		set dmap [hue::get_cuxd_device_map]
		array set cuxd_device_map $dmap
		foreach { cuxd_device o } [array get cuxd_device_map] {
			set tmp [split $o "_"]
			set bridge_id [lindex $tmp 0]
			set obj [lindex $tmp 1]
			set num [lindex $tmp 2]
			hue::write_log 4 "Device map entry: ${cuxd_device} = ${bridge_id} ${obj} ${num}"
			set time [expr {[clock seconds] + $hue::poll_state_interval}]
			if {[info exists update_schedule($o)]} {
				if {$update_schedule($o) <= $time} {
					# Keep earlier update time
					#hue::write_log 4 "Keep earlier update time"
					continue
				}
			}
			set update_schedule($o) $time
			hue::write_log 4 "Update of ${bridge_id} ${obj} ${num} scheduled for ${time}"
		}
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

proc update_cuxd_device {bridge_id obj num} {
	variable current_object_state
	set cuxd_devices [get_cuxd_devices_from_map $bridge_id $obj $num]
	if {[llength $cuxd_devices] == 0} {
		error "Failed to get CUxD devices for ${bridge_id} ${obj} ${num}"
	}
	foreach cuxd_device $cuxd_devices {
		set st [hue::get_object_state $bridge_id "${obj}s/${num}"]
		set cst ""
		if { [info exists current_object_state($cuxd_device)] } {
			set cst $current_object_state($cuxd_device)
		}
		if {$st != $cst} {
			set channel ""
			if {[regexp "^(\[^:\]+):(\\d+)$" $cuxd_device match d c]} {
				hue::update_cuxd_device_channel "CUxD.$d" $c [lindex $st 0] [lindex $st 1]
			} else {
				hue::update_cuxd_device_channels "CUxD.$cuxd_device" [lindex $st 0] [lindex $st 1] [lindex $st 2] [lindex $st 3] [lindex $st 4] [lindex $st 5]
			}
			set current_object_state($cuxd_device) $st
			hue::write_log 3 "Update of ${bridge_id} ${obj} ${num} successful (reachable=[lindex $st 0] on=[lindex $st 1] bri=[lindex $st 2] ct=[lindex $st 3] hue=[lindex $st 4] sat=[lindex $st 5])"
		} else {
			hue::write_log 4 "Update of ${bridge_id} ${obj} ${num} not required, state is unchanged"
		}
		set cuxd_device_last_update($cuxd_device) [clock seconds]
	}
}

proc read_from_channel {channel} {
	variable update_schedule
	variable last_schedule_update
	
	set len [gets $channel cmd]
	set cmd [string trim $cmd]
	hue::write_log 4 "Received command: $cmd"
	set response ""
	if {[regexp "^api_request\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+(.*)" $cmd match type bridge_id obj num method path json]} {
		set response [hue::request $type $bridge_id $method $path $json]
		set o "${bridge_id}_${obj}_${num}"
		
		if {$obj == "group"} {
			throttle_group_command
		}
		
		# The bridge needs some time until all values are up to date
		set cuxd_devices [get_cuxd_devices_from_map $bridge_id $obj $num]
		if {[llength $cuxd_devices] > 0} {
			# Device is mapped to a CUxD device
			set delay_seconds 1
			set time [expr {[clock seconds] + $delay_seconds}]
			set update_schedule($o) $time
			set response "Update of ${bridge_id} ${obj} ${num} scheduled for ${time}"
		}
		
	} elseif {[regexp "^reload$" $cmd match]} {
		set last_schedule_update 0
		set response "Reload scheduled"
	} else {
		set response "Invalid command"
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
	
	if { [catch {
		set dmap [hue::get_cuxd_device_map]
		array set cuxd_device_map $dmap
	} errmsg] } {
		hue::write_log 1 "Failed to get cuxd device map: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	
	after 10 main_loop
	
	if {$hue::hued_address == "0.0.0.0"} {
		socket -server accept_connection $hue::hued_port
	} else {
		socket -server accept_connection -myaddr $hue::hued_address $hue::hued_port
	}
	hue::write_log 3 "Hue daemon is listening for connections on ${hue::hued_address}:${hue::hued_port}"
}

if { "[lindex $argv 0 ]" != "daemon" } {
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
	cd /
	foreach fd {stdin stdout stderr} {
		close $fd
	}
	main
	vwait forever
}
exit 0
