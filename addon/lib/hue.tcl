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
	variable log_level_default 0
	variable log_level $log_level_default
	variable log_stderr -1
	variable api_log_default "off"
	variable api_log $api_log_default
	variable max_log_size 1000000
	# api_connect_timeout in milliseconds, 0=default tcl behaviour
	variable api_connect_timeout_default 0
	variable api_connect_timeout $api_connect_timeout_default
	variable lock_start_port 11200
	variable lock_socket
	variable lock_id_log_file 1
	variable lock_id_ini_file 2
	variable lock_id_bridge_start 3
	variable poll_state_interval_default 5
	variable poll_state_interval $poll_state_interval_default
	variable ignore_unreachable_default 0
	variable ignore_unreachable $ignore_unreachable_default
	variable devicetype "homematic-addon-hue#ccu"
	variable cuxd_ps "/usr/local/addons/cuxd/cuxd.ps"
	variable cuxd_xmlrpc_url "xmlrpc_bin://127.0.0.1:8701"
	variable hued_address "127.0.0.1"
	variable hued_port 1919
	variable group_throttling_settings_default "5:1000,10:2000"
	variable group_throttling_settings $group_throttling_settings_default
	# If we send on:false with transitiontime:x the hue bridge will turn off the light/group and set bri to 1 (bug?)
	# So it is better to not send transitiontime when turning light/group off
	# (always) remove / command triggered by (cuxd) / (never) remove
	variable remove_transitiontime_when_turning_off_default "cuxd"
	variable remove_transitiontime_when_turning_off $remove_transitiontime_when_turning_off_default
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

proc json_bool {val} {
	if {$val} { return "true" }
	return "false"
}

proc ::hue::set_log_stderr {l} {
	variable log_stderr
	set log_stderr $l
}

# error=1, warning=2, info=3, debug=4
proc ::hue::write_log {lvl msg {lock 1}} {
	variable log_level
	variable log_file
	variable lock_id_log_file
	variable max_log_size
	variable log_stderr
	if {$lvl <= $log_stderr} {
		catch {
			set date [clock seconds]
			set date [clock format $date -format {%Y-%m-%d %T}]
			puts stderr "\[${lvl}\] \[${date}\] ${msg}"
		}
	}
	if {$lvl <= $log_level} {
		if {$lock == 1} {
			acquire_lock $lock_id_log_file
		}
		set fd [open $log_file "a"]
		set date [clock seconds]
		set date [clock format $date -format {%Y-%m-%d %T}]
		set process_id [pid]
		puts $fd "\[${lvl}\] \[${date}\] \[${process_id}\] ${msg}"
		close $fd
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

proc ::hue::cross_product {point1 point2} {
	return [expr { [lindex $point1 0] * [lindex $point2 1] - [lindex $point1 1] * [lindex $point2 0] }]
}

proc ::hue::get_color_gamut {color_gamut_type} {
	set gamut_A [list [list 0.703 0.296] [list 0.214 0.709] [list 0.139 0.081]]
	set gamut_B [list [list 0.674 0.322] [list 0.408 0.517] [list 0.168 0.041]]
	set gamut_C [list [list 0.692 0.308] [list 0.17 0.7] [list 0.153 0.048]]
	set gamut_DEF [list [list 1.0 0.0] [list 0.0 1.0] [list 0.0 0.0]]
	
	if {$color_gamut_type == "A"} {
		return $gamut_A
	} elseif {$color_gamut_type == "B"} {
		return $gamut_B
	} elseif {$color_gamut_type == "C"} {
		return $gamut_C
	}
	return $gamut_DEF
}

# Check if the provided XYPoint can be recreated by a Hue lamp
proc ::hue::check_xy_in_lamps_reach {x y color_gamut} {
	set r [lindex $color_gamut 0]
	set g [lindex $color_gamut 1]
	set b [lindex $color_gamut 2]
	
	set v1 [list [expr {[lindex $g 0] - [lindex $r 0]}] [expr {[lindex $g 1] - [lindex $r 1]}]]
	set v2 [list [expr {[lindex $b 0] - [lindex $r 0]}] [expr {[lindex $b 1] - [lindex $r 1]}]]
	set q [list [expr {$x - [lindex $r 0]}] [expr {$y - [lindex $r 1]}]]
	set s [expr {[cross_product $q $v2] / [cross_product $v1 $v2]}]
	set t [expr {[cross_product $v1 $q] / [cross_product $v1 $v2]}]
	
	if {$s >= 0.0 && $t >= 0.0 && [expr {$s + $t}] <= 1.0} {
		return 1
	}
	return 0
}

proc ::hue::get_closest_point_to_line {point line_a line_b} {
	set APx [expr {[lindex $point 0] - [lindex $line_a 0]}]
	set APy [expr {[lindex $point 1] - [lindex $line_a 1]}]
	set ABx [expr {[lindex $line_b 0] - [lindex $line_a 0]}]
	set ABy [expr {[lindex $line_b 1] - [lindex $line_a 1]}]
	set ab2 [expr {$ABx * $ABx + $ABy * $ABy}]
	set ap_ab [expr {$APx * $ABx + $APy * $ABy}]
	set t [expr {$ap_ab / $ab2}]
	if {$t < 0.0} {
		set t 0.0
	} elseif {$t > 1.0} {
		set t 1.0
	}
	return [ list [expr {[lindex $line_a 0] + $ABx * $t}] [expr {[lindex $line_a 1] + $ABy * $t}] ]
}

# Calculate the distance between two XYPoints
proc ::hue::get_distance_between_two_points {point1 point2} {
	set dx [expr { [lindex $point1 0] - [lindex $point2 0] }]
	set dy [expr { [lindex $point1 1] - [lindex $point2 1] }]
	return [expr { sqrt($dx * $dx + $dy * $dy) }]
}

proc ::hue::get_closest_xy {x y color_gamut} {
	set point_xy [list $x $y]
	set pAB [get_closest_point_to_line $point_xy [lindex $color_gamut 0] [lindex $color_gamut 1]]
	set pAC [get_closest_point_to_line $point_xy [lindex $color_gamut 2] [lindex $color_gamut 0]]
	set pBC [get_closest_point_to_line $point_xy [lindex $color_gamut 1] [lindex $color_gamut 2]]
	
	set dAB [get_distance_between_two_points $point_xy $pAB]
	set dAC [get_distance_between_two_points $point_xy $pAC]
	set dBC [get_distance_between_two_points $point_xy $pBC]
	
	set shortest $dAB
	set closest_point $pAB
	if {$dAC < $shortest} {
		set shortest $dAC
		set closest_point $pAC
	}
	if {$dBC < $shortest} {
		set shortest $dBC
		set closest_point $pBC
	}
	return $closest_point
}


proc ::hue::gamma_correction {val} {
	if {$val > 0.04045} {
		set val [expr {pow(($val + 0.055) / (1.0 + 0.055), 2.4)}]
	} else {
		set val [expr {$val / 12.92}]
	}
	return $val
}

proc ::hue::reverse_gamma_correction {val} {
	if {$val <= 0.0031308} {
		set val [expr {$val * 12.92}]
	} else {
		set val [expr {(1.0 + 0.055) * pow($val, (1.0 / 2.4)) - 0.055}]
	}
	return $val
}

# https://github.com/benknight/hue-python-rgb-converter/blob/master/rgbxy/__init__.py
# https://github.com/Shnoo/js-CIE-1931-rgb-color-converter/blob/master/ColorConverter.js
# http://stackoverflow.com/a/22649803
# http://web.archive.org/web/20161023150649/http://www.developers.meethue.com:80/documentation/hue-xy-values
# https://github.com/home-assistant/home-assistant/blob/dev/homeassistant/util/color.py
# https://developers.meethue.com/develop/application-design-guidance/color-conversion-formulas-rgb-to-xy-and-back/
proc ::hue::rgb_to_xybri {red green blue {color_gamut ""} {scale_bri 1}} {
	if {$red   == ""} { set red   0 }
	if {$green == ""} { set green 0 }
	if {$blue  == ""} { set blue  0 }
	set r $red
	set g $green
	set b $blue
	if {[expr {$red + $green + $blue}] == 0} {
		return [list 0.0 0.0 0]
	}
	
	# Normalize values to 1
	set r [expr {$r / 255.0}]
	set g [expr {$g / 255.0}]
	set b [expr {$b / 255.0}]
	# Gamma correction, make colors more vivid
	set r [gamma_correction $r]
	set g [gamma_correction $g]
	set b [gamma_correction $b]
	# Convert to XYZ using the wide RGB D65 formula
	set X [expr {$r * 0.664511 + $g * 0.154324 + $b * 0.162028}]
	set Y [expr {$r * 0.283881 + $g * 0.668433 + $b * 0.047685}]
	set Z [expr {$r * 0.000088 + $g * 0.072310 + $b * 0.986039}]
	set x 0
	set y 0
	if {[expr {$X + $Y + $Z}] > 0} {
		set x [expr {$X / ($X + $Y + $Z)}]
		set y [expr {$Y / ($X + $Y + $Z)}]
	}
	set bri [expr {round($Y * 254)}]
	if {$scale_bri == 1} {
		set max 0
		if {$red > $max} { set max $red }
		if {$green > $max} { set max $green }
		if {$blue > $max} { set max $blue }
		if {$bri < $max} {
			set bri $max
		}
	}
	if {$bri < 0} {
		set bri 0
	} elseif {$bri == 0 && $Y > 0} {
		set bri 1
	} elseif {$bri > 254} {
		set bri 254
	}
	
	if {$color_gamut != ""} {
		if {![array exists $color_gamut]} {
			set color_gamut [get_color_gamut $color_gamut]
		}
		set in_reach [check_xy_in_lamps_reach $x $y $color_gamut]
		if {$in_reach == 0} {
			set closest [get_closest_xy $x $y $color_gamut]
			set x [lindex $closest 0]
			set y [lindex $closest 1]
		}
	}
	
	return [list [expr {round($x*1000.0)/1000.0}] [expr {round($y*1000.0)/1000.0}] $bri]
}

proc ::hue::xybri_to_rgb {x y bri {color_gamut ""} {scale_bri 1}} {
	if {$bri <= 0} {
		return [list 0 0 0]
	}
	if {$bri > 254} { set bri 254 }
	
	if {$color_gamut != ""} {
		if {![array exists $color_gamut]} {
			set color_gamut [get_color_gamut $color_gamut]
		}
		set in_reach [check_xy_in_lamps_reach $x $y $color_gamut]
		if {$in_reach == 0} {
			set closest [get_closest_xy $x $y $color_gamut]
			set x [lindex $closest 0]
			set y [lindex $closest 1]
		}
	}
	
	if {$y == 0} {
		set y 0.00000000001
	}
	# Calculate XYZ values
	set Y [expr {$bri / 254.0}]
	set X [expr {($Y / $y) * $x}]
	set Z [expr {($Y / $y) * (1.0 - $x - $y)}]
	# Convert to RGB using Wide RGB D65 conversion
	set r [expr {$X *  1.656492 + $Y * -0.354851 + $Z * -0.255038}]
	set g [expr {$X * -0.707196 + $Y *  1.655397 + $Z *  0.036152}]
	set b [expr {$X *  0.051713 + $Y * -0.121364 + $Z *  1.011530}]
	# Apply reverse gamma correction
	set r [reverse_gamma_correction $r]
	set g [reverse_gamma_correction $g]
	set b [reverse_gamma_correction $b]
	# Set all negative components to zero
	if {$r < 0} { set r 0 }
	if {$g < 0} { set g 0 }
	if {$b < 0} { set b 0 }
	# If one component is greater than 1, weight components by that value
	set max 0
	if {$r > $max} { set max $r }
	if {$g > $max} { set max $g }
	if {$b > $max} { set max $b }
	if {$max > 1} {
		set r [expr {$r / $max}]
		set g [expr {$g / $max}]
		set b [expr {$b / $max}]
	}
	if {$scale_bri} {
		set bri [expr $bri + 1]
	} else {
		set bri 255
	}
	set r [expr { round($r * $bri) }]
	set g [expr { round($g * $bri) }]
	set b [expr { round($b * $bri) }]
	return [list $r $g $b]
}

proc ::hue::get_debug_data {} {
	variable ini_file
	variable version_file
	
	set data ""
	
	append data "=== df ==========================================================================\n"
	if { [catch {
		append data [exec df]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== ps aux ======================================================================\n"
	if { [catch {
		append data [exec ps aux]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== top -Hb -n1 =================================================================\n"
	if { [catch {
		append data [exec top -Hb -n1]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== lsof ========================================================================\n"
	if { [catch {
		append data [exec lsof]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== dmesg =======================================================================\n"
	if { [catch {
		append data [exec dmesg]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== /var/log/messages ===========================================================\n"
	if { [catch {
		append data [exec cat /var/log/messages]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== VERSION =====================================================================\n"
	if { [catch {
		append data [exec cat $version_file]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== hue.conf ====================================================================\n"
	if { [catch {
		append data [exec cat $ini_file]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== hue-addon.log ===============================================================\n"
	if { [catch {
		append data [read_log]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	append data "=== hued status =================================================================\n"
	if { [catch {
		append data [hue::hued_command "status"]
	} errmsg] } {
		append data "ERROR: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	append data "\n\n"
	
	return $data
}

proc ::hue::hued_command {command {params {}}} {
	variable hued_address
	variable hued_port
	set params [join $params " "]
	hue::write_log 4 "Sending command to hued: ${command} ${params}"
	set chan [socket $hued_address $hued_port]
	puts $chan "${command} ${params}"
	flush $chan
	set res [read $chan]
	hue::write_log 4 "Command response from hued: $res"
	close $chan
	return $res
}


proc ::hue::discover_bridges {} {
	set curl "/usr/bin/curl"
	if { [file exists $curl] == 0 } {
		set curl "/usr/local/addons/cuxd/curl"
	}
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

proc ::hue::update_global_config {log_level api_log poll_state_interval ignore_unreachable api_connect_timeout group_throttling_settings remove_transitiontime_when_turning_off} {
	variable ini_file
	variable lock_id_ini_file
	
	write_log 4 "Updating global config: log_level=${log_level} api_log=${api_log} poll_state_interval=${poll_state_interval} ignore_unreachable=${ignore_unreachable} api_connect_timeout=${api_connect_timeout} group_throttling_settings=${group_throttling_settings} remove_transitiontime_when_turning_off=${remove_transitiontime_when_turning_off}"
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r+]
	ini::set $ini "global" "log_level" $log_level
	ini::set $ini "global" "api_log" $api_log
	ini::set $ini "global" "api_connect_timeout" $api_connect_timeout
	ini::set $ini "global" "poll_state_interval" $poll_state_interval
	ini::set $ini "global" "group_throttling_settings" $group_throttling_settings
	ini::set $ini "global" "remove_transitiontime_when_turning_off" $remove_transitiontime_when_turning_off
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
	variable group_throttling_settings
	variable remove_transitiontime_when_turning_off
	
	write_log 4 "Reading global config"
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r]
	catch {
		set log_level [expr { 0 + [::ini::value $ini "global" "log_level" $log_level] }]
		set api_log [::ini::value $ini "global" "api_log" $api_log]
		set api_connect_timeout [expr { 0 + [::ini::value $ini "global" "api_connect_timeout" $api_connect_timeout] }]
		set poll_state_interval [expr { 0 + [::ini::value $ini "global" "poll_state_interval" $poll_state_interval] }]
		set ignore_unreachable [expr { 0 + [::ini::value $ini "global" "ignore_unreachable" $ignore_unreachable] }]
		set group_throttling_settings [::ini::value $ini "global" "group_throttling_settings" $group_throttling_settings]
		set remove_transitiontime_when_turning_off [::ini::value $ini "global" "remove_transitiontime_when_turning_off" $remove_transitiontime_when_turning_off]
	}
	ini::close $ini
	release_lock $lock_id_ini_file
}

proc ::hue::get_config_json {} {
	variable ini_file
	variable lock_id_ini_file
	variable log_level_default
	variable log_level
	variable api_log_default
	variable api_log
	variable api_connect_timeout_default
	variable api_connect_timeout
	variable poll_state_interval_default
	variable poll_state_interval
	variable ignore_unreachable_default
	variable ignore_unreachable
	variable group_throttling_settings_default
	variable group_throttling_settings
	variable remove_transitiontime_when_turning_off_default
	variable remove_transitiontime_when_turning_off
	
	set cuxd_version [get_cuxd_version]
	
	acquire_lock $lock_id_ini_file
	set ini [ini::open $ini_file r]
	set json "\{\"cuxd_version\":\"${cuxd_version}\","
	append json "\"global\":\{"
	append json "\"log_level\":\{\"default\":${log_level_default},\"value\":${log_level}\},"
	append json "\"api_log\":\{\"default\":\"${api_log_default}\",\"value\":\"${api_log}\"\},"
	append json "\"api_connect_timeout\":\{\"default\":${api_connect_timeout_default},\"value\":${api_connect_timeout}\},"
	append json "\"poll_state_interval\":\{\"default\":${poll_state_interval_default},\"value\":${poll_state_interval}\},"
	append json "\"group_throttling_settings\":\{\"default\":\"${group_throttling_settings_default}\",\"value\":\"${group_throttling_settings}\"\},"
	append json "\"ignore_unreachable\":\{\"default\":[json_bool $ignore_unreachable_default],\"value\":[json_bool $ignore_unreachable]\},"
	append json "\"remove_transitiontime_when_turning_off\":\{\"default\":\"${remove_transitiontime_when_turning_off_default}\",\"value\":\"${remove_transitiontime_when_turning_off}\"\}"
	append json "\},"
	append json "\"bridges\":\["
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

proc ::hue::get_cuxd_version {} {
	return [exec /usr/local/addons/cuxd/cuxd -v]
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
	catch { close $sock }
	if {$response == ""} {
		error "Failed to connect to server at address $ip"
	}
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
	acquire_bridge_lock $bridge_id
	if {[catch {
		set result [api_request $type $bridge(ip) $bridge(port) $bridge(username) $method $path $data]
	} errmsg]} {
		release_bridge_lock $bridge_id
		return -code 1 -errorcode $::errorCode -errorinfo $::errorInfo $errmsg
	}
	release_bridge_lock $bridge_id
	return $result
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
	array set dmap {}
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
	array set dmap {}
	
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

proc ::hue::update_cuxd_device_state {device astate} {
	variable ignore_unreachable
	variable cuxd_xmlrpc_url
	array set state $astate
	
	set address $device
	if {[regexp "^CUxD\.(.*)" $address match d]} {
		set address $d
	}
	set device $address
	set channel ""
	if {[regexp "^(\[^:\]+):(\\d+)$" $address match d c]} {
		set device $d
		set channel $c
	}
	
	set reachable 1
	if {$state(reachable) == "false" || $state(reachable) == 0} {
		set reachable 0
		if {$ignore_unreachable} {
			hue::write_log 4 "ignoring unreachable device ${address}, no update"
			return
		}
	}
	
	regexp "^CUX(\\d\\d)(\\d\\d)" $address match dtype dtype2
	set dtype [ expr 0 + $dtype ]
	set dtype2 [ expr 0 + $dtype2 ]
	
	set on 1
	if {$state(on) == "false" || $state(on) == 0 || $reachable == 0} {
		set on 0
	}
	
	set bri 0
	if {$state(bri) != ""} {
		set bri $state(bri)
	}
	if {$on == 0} {
		set bri 0
	} else {
		if {$bri == 0} {
			set bri 1
		}
	}
	
	set ct 0
	if {$state(ct) != ""} {
		set ct $state(ct)
	}
	
	set hue 0
	if {$state(hue) != ""} {
		set hue $state(hue)
	}
	
	set sat 0
	if {$state(sat) != ""} {
		set sat $state(sat)
	}
	
	set xy [list 0 0]
	if {$state(xy) != ""} {
		set xy $state(xy)
	}
	
	hue::write_log 4 "update_device_channels ${address} set states: reachable=${reachable} on=${on} bri=${bri} ct=${ct} hue=${hue} sat=${sat} xy=${xy}"
	
	set s ""
	if {$dtype == 40} {
		# Switch
		set s "dom.GetObject(\"CUxD.${address}.SET_STATE\").State(${on});"
	} elseif {$dtype == 28 && $dtype2 == 1} {
		# System.Exec
		set s2 "Write(xmlrpc.GetObjectByHSSAddress(interfaces.Get('CUxD'), '${device}').HssType());"
		array set res [rega_script $s2]
		set hss_type [string trim [encoding convertfrom utf-8 $res(STDOUT)]]
		if {$hss_type == "VIR-LG-RGBW-DIM"} {
			set states [list]
			set level [expr round((double($bri)*1000.0) / 254.0)/1000.0]
			lappend states "LEVEL=${level}"
			if {$ct > 0} {
				set white [expr round(1000000.0 / double($ct))]
				if {$white > 6500} {
					set white 6500
				}
				lappend states "WHITE=${white}"
			}
			if {[lindex $xy 0] > 0 && [lindex $xy 1] > 0} {
				set rgb [hue::xybri_to_rgb [lindex $xy 0] [lindex $xy 1] $bri $state(color_gamut_type)]
				set rgb [join $rgb ","]
				lappend states "RGBW=${rgb}"
			}
			#hue::write_log 0 "${address}: $states"
			set states [join $states "&"]
			set s "dom.GetObject(\"CUxD.${address}.SET_STATES\").State(\"${states}\");"
			#set s "
			#	if ((dom.GetObject(\"CUxD.${address}.LEVEL\").Value() != ${level}) ||
			#		(dom.GetObject(\"CUxD.${address}.RGBW\").Value() != \"rgb(${rgb},0)\") ||
			#		(dom.GetObject(\"CUxD.${address}.WHITE\").Value() != ${white})) \{
			#		dom.GetObject(\"CUxD.${address}.SET_STATES\").State(\"${states}\");
			#	\}
			#"
		} else {
			set s "dom.GetObject(\"CUxD.${address}.SET_STATE\").State(${on});"
			#if {$on == 1} {
			#	set s "
			#		if (!dom.GetObject(\"CUxD.${address}.STATE\").State()) \{
			#			dom.GetObject(\"CUxD.${address}.SET_STATE\").State(${on});
			#		\}
			#	"
			#} else {
			#	set s "
			#		if (dom.GetObject(\"CUxD.${address}.STATE\").State()) \{
			#			dom.GetObject(\"CUxD.${address}.SET_STATE\").State(${on});
			#		\}
			#	"
			#}
		}
	} elseif {$dtype == 28 && $dtype2 == 2} {
		# System.Multi-DIM-Exec
		set mm [get_cuxd_channels_min_max $device]
		set bri_f 0.0
		if {$bri > 0 && [lindex $mm 1] > 0} {
			set bri_f [expr round(($bri*100.0) / [lindex $mm 1])/100.0 ]
			if {$bri_f > 1.0} { set bri_f 1.0 }
			if {$bri_f < 0.01 && $bri > 0} { set bri_f 0.01 }
		}
		if {$ct > 0 && [expr [lindex $mm 3] - [lindex $mm 2]] > 0} {
			set ct [expr round((($ct - [lindex $mm 2])*100.0) / (double([lindex $mm 3] - [lindex $mm 2])))/100.0 ]
			if {$ct > 1.0} { set ct 1.0 }
		}
		if {$hue > 0 && [lindex $mm 5] > 0} {
			set hue [expr round(($hue*100.0) / [lindex $mm 5])/100.0 ]
			if {$hue > 1.0} { set hue 1.0 }
		}
		if {$sat > 0 && [lindex $mm 7] > 0} {
			set sat [expr round(($sat*100.0) / [lindex $mm 7])/100.0 ]
			if {$sat > 1.0} { set sat 1.0 }
		}
		set s "
			if (dom.GetObject(\"CUxD.${device}:2.LEVEL\")) \{
				dom.GetObject(\"CUxD.${device}:2.SET_STATE\").State(${bri_f});
			\}
			if (dom.GetObject(\"CUxD.${device}:3.LEVEL\")) \{
				dom.GetObject(\"CUxD.${device}:3.SET_STATE\").State(${ct});
			\}
			if (dom.GetObject(\"CUxD.${device}:4.LEVEL\")) \{
				dom.GetObject(\"CUxD.${device}:4.SET_STATE\").State(${hue});
			\}
			if (dom.GetObject(\"CUxD.${device}:5.LEVEL\")) \{
				dom.GetObject(\"CUxD.${device}:5.SET_STATE\").State(${sat});
			\}
		"
	} else {
		set s "dom.GetObject(\"CUxD.${address}.SET_STATE\").State(${on});"
	}
	
	hue::write_log 4 "rega_script ${s}"
	rega_script $s
}

proc ::hue::get_object_state {bridge_id obj_type obj_id} {
	set data [hue::request "status" $bridge_id "GET" "/${obj_type}s/${obj_id}"]
	return [hue::get_object_state_from_json $bridge_id $obj_type $obj_id $data]
}

proc ::hue::get_object_state_from_json {bridge_id obj_type obj_id data {cached_object_states ""}} {
	set calc_group_brightness 1
	array set object_states {}
	if {$cached_object_states != ""} {
		array set object_states $cached_object_states
	}
	array set state {}
	
	if { [regexp {\"reachable\"\s*:\s*(true|false)} $data match val] } {
		set state(reachable) $val
	} else {
		if {[regexp {\"error\"(.*)} $data match val]} {
			set state(reachable) "false"
		} else {
			set state(reachable) "true"
		}
	}
	
	if { [regexp {\"any_on\"\s*:\s*(true|false)} $data match val] } {
		set state(on) $val
	} else {
		if { [regexp {\"on\"\s*:\s*(true|false)} $data match val] } {
			set state(on) $val
		} else {
			set state(on) "false"
		}
	}
	
	set state(color_gamut_type) ""
	if { [regexp {\"colorgamuttype\"\s*:\s*\"([^\"]+)\"} $data match val] } {
		set state(color_gamut_type) $val
	}
	
	set state(type) ""
	if { [regexp {\"type\"\s*:\s*\"([^\"]+)\"} $data match val] } {
		set state(type) $val
	}
	
	set state(lights) [list]
	set state(bri) ""
	if {$obj_type == "group"} {
		#"lights":["11","10","9"]
		if [regexp {\"lights\"\s*:\s*\[(["\d,]+)\]} $data match lights] {
			set light_num 0
			set bri_sum 0
			set any_reachable 0
			foreach light [split $lights ","] {
				set light_num [expr {$light_num + 1}]
				set light [string map {"\"" ""} $light]
				lappend state(lights) $light
				
				array set light_state {}
				if {[info exists object_states(${bridge_id}_light_${light})] } {
					array set light_state $object_states(${bridge_id}_light_${light})
				} else {
					array set light_state [hue::get_object_state $bridge_id "light" $light]
				}
				
				if {$light_state(bri) != ""} {
					set bri_sum [expr {$bri_sum + $light_state(bri)}]
				} elseif {$light_state(on) == "true"} {
					set bri_sum [expr {$bri_sum + 254}]
				}
				if {$any_reachable == 0 && $light_state(reachable) == "true"} {
					set any_reachable 1
				}
			}
			set val [expr {$bri_sum / $light_num}]
			if {$any_reachable == 0} {
				set state(reachable) "false"
			} else {
				set state(reachable) "true"
			}
			if {$calc_group_brightness} {
				hue::write_log 4 "Calculated group ${obj_id} values: reachable=${any_reachable}, brightness=${val}"
				set state(bri) $val
			}
		}
	} else {
		if {[regexp {\"bri\"\s*:\s*(\d+)} $data match val]} {
			set state(bri) [expr {0 + $val}]
		}
	}
	
	set state(ct) ""
	if {[regexp {\"ct\"\s*:\s*(\d+)} $data match val]} {
		set state(ct) [expr {0 + $val}]
	}
	
	set state(hue) ""
	if {[regexp {\"hue\"\s*:\s*(\d+)} $data match val]} {
		set state(hue) [expr {0 + $val}]
	}
	
	set state(sat) ""
	if {[regexp {\"sat\"\s*:\s*(\d+)} $data match val]} {
		set state(sat) [expr {0 + $val}]
	}
	
	set state(xy) ""
	if {[regexp {\"xy\"\s*:\s*\[([\d+\.]+),([\d+\.]+)\]} $data match x y]} {
		set x [expr {round($x*1000.0)/1000.0}]
		set y [expr {round($y*1000.0)/1000.0}]
		set state(xy) [list $x $y]
	}
	
	return [array get state]
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

proc ::hue::create_cuxd_device {sid type serial name bridge_id obj_type obj_id {transitiontime ""}} {
	variable cuxd_xmlrpc_url
	set dtype 28
	set dtype2 1
	set color 0
	
	if {$type == "rgbw"} {
		array set st [hue::get_object_state $bridge_id $obj_type $obj_id]
		if {[string tolower $st(type)] == "extended color light"} {
			set color 1
		} elseif {$st(color_gamut_type) != ""} {
			set color 1
		}
		if {$obj_type == "group"} {
			foreach light_id $st(lights) {
				array set stl [hue::get_object_state $bridge_id "light" $light_id]
				if {[string tolower $stl(type)] == "extended color light"} {
					set color 1
					break
				}
				elseif {$stl(color_gamut_type) != ""} {
					set color 1
					break
				}
			}
		}
	}
	
	if {$serial <= 0} {
		set serial [get_free_cuxd_device_serial $dtype $dtype2]
	}
	set serial [expr {0 + $serial}]
	
	set device "CUX[format %02s $dtype][format %02s $dtype2][format %03s $serial]"
	set dbase ""
	set dcontrol 0
	set dname ""
	if {$type == "switch"} {
		set dbase "VIR-LG-ONOFF"
		set dcontrol 1
		set dname "${name} SWITCH"
	} elseif {$type == "rgbw"} {
		set dbase "VIR-LG-RGBW-DIM"
		set dcontrol 4
		set dname "${name} RGBW"
	}
	
	set data "dtype=${dtype}&dtype2=${dtype2}&dserial=${serial}&dname=[urlencode $dname]&dbase=${dbase}&dcontrol=${dcontrol}"
	
	hue::write_log 4 "Creating cuxd ${type} device with serial ${serial}"
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
	
	set struct_dev ""
	set struct_chn ""
	if {$type == "switch"} {
		set command_short "/usr/local/addons/hue/hue.tcl ${bridge_id} ${obj_type} ${obj_id} on:false"
		set command_long "/usr/local/addons/hue/hue.tcl ${bridge_id} ${obj_type} ${obj_id} on:true"
		if {$transitiontime != ""} {
			append command_short " transitiontime:${transitiontime}"
			append command_long " transitiontime:${transitiontime}"
		}
		set struct_chn [list [list "CMD_EXEC" [list "bool" 1]] [list "CMD_SHORT" [list "string" $command_short]] [list "CMD_LONG" [list "string" $command_long]]]
	} elseif {$type == "rgbw"} {
		set command_long "/usr/local/addons/hue/hue.tcl ${bridge_id} ${obj_type} ${obj_id}"
		if {$transitiontime != ""} {
			append command_long " transitiontime:${transitiontime}"
		}
		set struct_dev [list [list "RGBW" [list "bool" $color]]]
		set struct_chn [list [list "CMD_EXEC" [list "bool" 1]] [list "CMD_LONG" [list "string" $command_long]]]
	}
	if {$struct_dev != ""} {
		xmlrpc $cuxd_xmlrpc_url putParamset [list string $device] [list string "MASTER"] [list struct $struct_dev]
	}
	if {$struct_chn != ""} {
		xmlrpc $cuxd_xmlrpc_url putParamset [list string "${device}:1"] [list string "MASTER"] [list struct $struct_chn]
	}
	
	after 5000
	
	set ch1 [encoding convertfrom identity [string map {. ,} "${name}"]]
	
	set s "
		object device = xmlrpc.GetObjectByHSSAddress(interfaces.Get('CUxD'), '${device}');
		if (device) {
			string channelId;
			foreach(channelId, device.Channels()) {
				object channel = dom.GetObject(channelId);
				if (channel.ChnNumber() == 1) {
					channel.Name('${ch1}');
					WriteLine(channel.Name());
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

proc ::hue::create_cuxd_switch_device {sid serial name bridge_id obj_type obj_id {transitiontime ""}} {
	return [hue::create_cuxd_device $sid "switch" $serial $name $bridge_id $obj_type $obj_id $transitiontime]
}

proc ::hue::create_cuxd_rgbw_device {sid serial name bridge_id obj_type obj_id {transitiontime ""}} {
	return [hue::create_cuxd_device $sid "rgbw" $serial $name $bridge_id $obj_type $obj_id $transitiontime]
}

proc ::hue::create_cuxd_dimmer_device {sid serial name bridge_id obj num ct_min ct_max {color 0} {transitiontime ""}} {
	variable cuxd_xmlrpc_url
	set dtype 28
	set dtype2 2
	
	if {$serial <= 0} {
		set serial [get_free_cuxd_device_serial $dtype $dtype2]
	}
	set serial [expr {0 + $serial}]
	
	set dbase "HM-LC-Dim1T-FM"
	set device "CUX[format %02s $dtype][format %02s $dtype2][format %03s $serial]"
	set command "/usr/local/addons/hue/hue.tcl ${bridge_id} ${obj} ${num} ct_min:${ct_min}"
	if {$transitiontime != ""} {
		append command " transitiontime:${transitiontime}"
	}
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
		object device = xmlrpc.GetObjectByHSSAddress(interfaces.Get('CUxD'), '${device}');
		if (device) {
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
	"
	hue::write_log 4 "rega_script ${s}"
	array set res [rega_script $s]
	set stdout [encoding convertfrom utf-8 $res(STDOUT)]
	hue::write_log 4 "${stdout}"
	
	return $device
	
	set s "
		object device = xmlrpc.GetObjectByHSSAddress(interfaces.Get('CUxD'), '${device}');
		if (device && (device.ReadyConfig() == false)) {
			var devId = id;
			Call('devices.fn::setReadyConfig()');
			WriteLine(id);
		}
	"
	##hue::write_log 4 "rega_script ${s}"
	array set res [rega_script $s]
	set device_id [string trim [encoding convertfrom utf-8 $res(STDOUT)]]
	#puts $device_id
	
	return $device
	
	set s "
		object device = xmlrpc.GetObjectByHSSAddress(interfaces.Get('CUxD'), '${device}');
		if (device && (device.ReadyConfig() == false)) {
			string channelId;
			foreach(channelId, device.Channels()) {
				object channel = dom.GetObject(channelId);
				channel.ReadyConfig(true);
			}
			device.ReadyConfig(true, false);
			WriteLine(id);
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
	#puts $response
}

hue::read_global_config

#puts [hue::rgb_to_xybri 100 100 100]
#puts [hue::xybri_to_rgb 0.322726720866 0.329022909559 32]
#puts [hue::get_debug_data]
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
