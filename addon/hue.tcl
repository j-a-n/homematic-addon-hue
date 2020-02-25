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

# CUXD_DEVICE = <cuxd-device>
# CUXD_TRIGGER_CH = <channel>
# CUXD_VALUE<channel> = <value>
# CUXD_MAXVALUE<channel> = <value>
#
# $env(CUXD_DEVICE)
# $env(CUXD_TRIGGER_CH)
# $env(CUXD_VALUE2)
# $env(CUXD_VALUE3)
# $env(CUXD_VALUE4)
# $env(CUXD_VALUE5)
# $env(CUXD_MAXVALUE2)
# $env(CUXD_MAXVALUE3)
# $env(CUXD_MAXVALUE4)
# $env(CUXD_MAXVALUE5)

source /usr/local/addons/hue/lib/hue.tcl

variable object_states

set language "en-US"
catch {
	set language $::env(LANGUAGE)
}
set language [string range $language 0 1]

proc usage {} {
	set bridge_ids [hue::get_config_bridge_ids]
	global argv0
	variable language
	
	if {$language == "de"} {
		puts stderr "Aufruf: ${argv0} <Bridge-ID> <Befehl>"
		puts stderr ""
		puts stderr "Verfügbare Bridge-IDs: ${bridge_ids}"
		puts stderr ""
		puts stderr "Verfügbare Befehle:"
		puts stderr "  request <Methode> <Ressource> \[Daten\]     Eine Anfrage an die Rest-API senden"
		puts stderr "    Methode   : GET,POST,PUT oder DELETE"
		puts stderr "    Ressource : URL-Pfad"
		puts stderr "    Daten     : optionale JSON-Daten"
		puts stderr ""
		puts stderr "  light <Lampen-ID> \[Parameter:Wert\]...     Eine Lampe steuern"
		puts stderr "    Lampen-ID      : ID der Lampe die gesteuert werden soll"
		puts stderr "    Parameter:Wert : Komma-getrennte Parameter:Wert-Paare"
		puts stderr "                     Mögliche Parameter sind: on,sat,bri,bri_inc,hue,hue_inc,xy,ct,rgb,rgb_bri,transitiontime,bri_mode,sleep,ct_min"
		puts stderr ""
		puts stderr "  group <Gruppen-ID> \[Parameter:Wert\]...    Eine Gruppe steuen"
		puts stderr "    Gruppen-ID     : ID der Gruppe die gesteuert werden soll"
		puts stderr "    Parameter:Wert : Komma-getrennte Parameter:Wert-Paare"
		puts stderr "                     Mögliche Parameter sind: on,sat,bri,bri_inc,hue,hue_inc,xy,ct,rgb,rgb_bri,scene,transitiontime,bri_mode,sleep,ct_min"
	} else {
		puts stderr "usage: ${argv0} <bridge-id> <command>"
		puts stderr ""
		puts stderr "available bridge ids: ${bridge_ids}"
		puts stderr ""
		puts stderr "possible commands:"
		puts stderr "  request <method> <resource> \[data\]     send a request to rest api"
		puts stderr "    method   : one of GET,POST,PUT,DELETE"
		puts stderr "    resource : URL path"
		puts stderr "    data     : optional json data"
		puts stderr ""
		puts stderr "  light <light-id> \[parm:val\]...         control a light"
		puts stderr "    light-id : id of the light to control"
		puts stderr "    parm:val : parameter:value pairs separated by a colon"
		puts stderr "               some of the possible paramers are: on,sat,bri,bri_inc,hue,hue_inc,xy,ct,rgb,rgb_bri,transitiontime,bri_mode,sleep,ct_min"
		puts stderr ""
		puts stderr "  group <group-id> \[parm:val\]...         control a group"
		puts stderr "    group-id : id of the group to control"
		puts stderr "    parm:val : parameter and value pairs separated by a colon"
		puts stderr "               some of the possible paramers are: on,sat,bri,bri_inc,hue,hue_inc,xy,ct,rgb,rgb_bri,scene,transitiontime,bri_mode,sleep,ct_min"
	}
}

proc get_object_state {bridge_id obj_type obj_id} {
	variable object_states
	
	set full_id "${bridge_id}_${obj_type}_${obj_id}"
	if { ![info exists object_states($full_id)] } {
		set response [hue::hued_command "object_state" [list $bridge_id $obj_type $obj_id]]
		if {$response != ""} {
			set object_states($full_id) $response
		} else {
			set object_states($full_id) [hue::get_object_state $bridge_id $obj_type $obj_id]
		}
	}
	return $object_states($full_id)
}

# Do not repeatedly send the ON command as this will slow the responsiveness of the bridge.
proc auto_on {aparams bridge_id obj_type obj_id} {
	array set params $aparams
	if {[lsearch [array names params] "on"] != -1} {
		return ""
	}
	if {[lsearch [array names params] "bri"] != -1} {
		if {$params(bri) == 0} {
			hue::write_log 4 "${obj_type}=${obj_id}, bri=0, auto turn off"
			return "false"
		}
	}
	array set st [get_object_state $bridge_id $obj_type $obj_id]
	if {$st(on) == "false"} {
		hue::write_log 4 "${obj_type}=${obj_id}, auto turn on"
		return "true"
	}
	return ""
}

proc main {} {
	global argc
	global argv
	global env
	variable language
	
	if {[string tolower [lindex $argv 0]] == "hued_command"} {
		if {$argc < 2} {
			usage
			exit 1
		}
		puts [hue::hued_command [lindex $argv 1]]
		return
	}
	
	if {$argc < 3} {
		usage
		exit 1
	}
	
	set bridge_id [string tolower [lindex $argv 0]]
	
	if {[string tolower [lindex $argv 1]] == "request"} {
		if {$argc < 4} {
			usage
			exit 1
		}
		puts [hue::request "command" $bridge_id [lindex $argv 2] [lindex $argv 3] [lindex $argv 4]]
		return
	}
	
	set obj_type [string tolower [lindex $argv 1]]
	if {$obj_type != "light" && $obj_type != "group"} {
		usage
		exit 1
	}
	
	set obj_id  [lindex $argv 2]
	set bri_mode "abs"
	set sleep 0
	set ct_min 153
	array set params {}
	set rgb ""
	set rgb_bri 0
	
	foreach a [lrange $argv 2 end] {
		regexp {(.*)[=:](.*$)} $a match k v
		if {[info exists v]} {
			if {$k == "sleep"} {
				set sleep [expr {0 + $v}]
			} elseif {$k == "ct_min"} {
				set ct_min [expr {0 + $v}]
			} elseif {$k == "bri_mode"} {
				if {$v == "abs" || $v == "inc"} {
					set bri_mode $v
				}
			} elseif {$k == "xy"} {
				set params($k) "\[${v}\]"
			} elseif {$k == "rgb"} {
				set rgb [split $v ","]
			} elseif {$k == "rgb_bri"} {
				set rgb [split $v ","]
				set rgb_bri 1
			} elseif {$k == "scene"} {
				if {![regexp {[a-zA-Z0-9\-]{15}} $v]} {
					# Not a scene id
					array set scene_map [hue::get_scene_name_id_map $bridge_id]
					if [catch {
						set v $scene_map($v)
					} err] {
						if {$language == "de"} {
							error "Szene mit Namen ${v} nicht gefunden."
						} else {
							error "Failed to find scene with name ${v}."
						}
					}
				}
				set params($k) "\"${v}\""
			} else {
				set nm ""
				regexp {^(-?\d+)$} $v match nm
				if {$nm != "" || $v == "true" || $v == "false"} {
					set params($k) $v
				} else {
					set params($k) "\"${v}\""
				}
			}
		}
	}
	
	if {[info exists env(CUXD_TRIGGER_CH)]} {
		set chan $env(CUXD_TRIGGER_CH)
		
		if {$chan == 1} {
			puts [hue::hued_command "update_object_state" [list $bridge_id $obj_type $obj_id]]
			return
		}
		
		set param ""
		set val_in $env(CUXD_VALUE${chan})
		set val $val_in
		
		if {$chan == 2} {
			set param "bri"
			# 0 - 254
			if {$val > 0 && $val < 254 && $bri_mode == "inc"} {
				set param "bri_inc"
				array set st [get_object_state $bridge_id $obj_type $obj_id]
				set bri $st(bri)
				if {$bri == ""} { set bri 0 }
				set val [expr {$val - $bri}]
			}
		} elseif {$chan == 3} {
			set param "ct"
			# mirek, range depends on device (i.e. 153 - 500)
			set val [expr {$val + $ct_min}]
		} elseif {$chan == 4} {
			set param "hue"
			# 0 - 65535
		} elseif {$chan == 5} {
			set param "sat"
			# 0 - 254
		}
		
		if {$param != "" && [lsearch [array names params] $param] == -1} {
			set params($param) $val
		}
	}
	
	set on [auto_on [array get params] $bridge_id $obj_type $obj_id]
	if {$on == "true" || $on == "false"} {
		set params(on) $on
	}
	
	if {$sleep > 0} {
		hue::write_log 4 "Sleep ${sleep} ms"
		after $sleep
	}
	
	set obj_action 1
	if {$obj_type == "group" && [lsearch [array names params] "scene"] == -1} {
		array set st [get_object_state $bridge_id $obj_type $obj_id]
		set num_lights [llength $st(lights)]
		if {$num_lights > 0 && $num_lights < 10} {
			set obj_action 0
			foreach light_id $st(lights) {
				if {$rgb != ""} {
					array set stc [get_object_state $bridge_id "light" $light_id]
					set x_y_bri [hue::rgb_to_xybri [lindex $rgb 0] [lindex $rgb 1] [lindex $rgb 2] $stc(color_gamut_type)]
					set params(xy) "\[[lindex $x_y_bri 0],[lindex $x_y_bri 1]\]"
					if {$rgb_bri} {
						set params(bri) [lindex $x_y_bri 2]
					}
				}
				puts -nonewline [hue::hued_command "object_action" [list $bridge_id "light" $light_id [array get params]]]
			}
		}
	}
	if {$obj_action} {
		if {$rgb != ""} {
			array set stc [get_object_state $bridge_id $obj_type $obj_id]
			set x_y_bri [hue::rgb_to_xybri [lindex $rgb 0] [lindex $rgb 1] [lindex $rgb 2] $stc(color_gamut_type)]
			set params(xy) "\[[lindex $x_y_bri 0],[lindex $x_y_bri 1]\]"
			if {$rgb_bri} {
				set params(bri) [lindex $x_y_bri 2]
			}
		}
		puts -nonewline [hue::hued_command "object_action" [list $bridge_id $obj_type $obj_id [array get params]]]
	}
	hue::hued_command "update_object_state" [list $bridge_id $obj_type $obj_id]
}

if { [ catch {
	#catch {cd [file dirname [info script]]}
	main
} err ] } {
	hue::write_log 1 "Error in hue.tcl: ${err}"
	puts stderr "ERROR: ${err}"
	exit 1
}
exit 0


