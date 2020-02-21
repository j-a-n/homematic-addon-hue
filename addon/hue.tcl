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

variable update_device_channels_after 3

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
		puts stderr "                     Mögliche Parameter sind: on,sat,bri,hue,xy,ct,rgb,rgb_bri,transitiontime,bri_mode,sleep,ct_min"
		puts stderr ""
		puts stderr "  group <Gruppen-ID> \[Parameter:Wert\]...    Eine Gruppe steuen"
		puts stderr "    Gruppen-ID     : ID der Gruppe die gesteuert werden soll"
		puts stderr "    Parameter:Wert : Komma-getrennte Parameter:Wert-Paare"
		puts stderr "                     Mögliche Parameter sind: on,sat,bri,hue,xy,ct,rgb,rgb_bri,scene,transitiontime,bri_mode,sleep,ct_min"
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
		puts stderr "               some of the possible paramers are: on,sat,bri,hue,xy,ct,rgb,rgb_bri,transitiontime,bri_mode,sleep,ct_min"
		puts stderr ""
		puts stderr "  group <group-id> \[parm:val\]...         control a group"
		puts stderr "    group-id : id of the group to control"
		puts stderr "    parm:val : parameter and value pairs separated by a colon"
		puts stderr "               some of the possible paramers are: on,sat,bri,hue,xy,ct,rgb,rgb_bri,scene,transitiontime,bri_mode,sleep,ct_min"
	}
}

proc main {} {
	global argc
	global argv
	global env
	variable update_device_channels_after
	variable language
	
	if {[string tolower [lindex $argv 0]] == "hued_command"} {
		if {$argc < 2} {
			usage
			exit 1
		}
		puts [hue::hued_command [lindex $argv 1]]
		return
	}
	
	set bridge_id [string tolower [lindex $argv 0]]
	set cmd [string tolower [lindex $argv 1]]
	set num [lindex $argv 2]
	set bri_mode "abs"
	set sleep 0
	set ct_min 153
	
	if {$cmd == "request"} {
		if {$argc < 4} {
			usage
			exit 1
		}
		puts [hue::request "command" $bridge_id [lindex $argv 2] [lindex $argv 3] [lindex $argv 4]]
	} else {
		if {$argc < 3} {
			usage
			exit 1
		}
		set path ""
		set obj_type ""
		set obj_id ""
		if {$cmd == "light"} {
			set obj_type "light"
			set obj_id [lindex $argv 2]
			set path "lights/${obj_id}/state"
		} elseif {$cmd == "group"} {
			set obj_type "group"
			set obj_id [lindex $argv 2]
			set path "groups/${obj_id}/action"
		} else {
			usage
			exit 1
		}
		set keys [list]
		set json "\{"
		foreach a [lrange $argv 2 end] {
			regexp {(.*)[=:](.*$)} $a match k v
			if {[info exists v]} {
				lappend keys $k
				if {$k == "sleep"} {
					set sleep [expr {0 + $v}]
				} elseif {$k == "ct_min"} {
					set ct_min [expr {0 + $v}]
				} elseif {$k == "bri_mode"} {
					if {$v == "abs" || $v == "inc"} {
						set bri_mode $v
					}
				} elseif {$k == "xy"} {
					append json "\"${k}\":\[${v}\],"
				} elseif {$k == "rgb_bri" || $k == "rgb"} {
					set rgb [split $v ","]
					set color_gamut_type ""
					if {$obj_type == "light"} {
						set color_gamut_type [hue::get_light_color_gamut_type $bridge_id $obj_id]
					}
					set res [hue::rgb_to_xybri [lindex $rgb 0] [lindex $rgb 1] [lindex $rgb 2] $color_gamut_type]
					set x [lindex $res 0]
					set y [lindex $res 1]
					set bri [lindex $res 2]
					append json "\"xy\":\[${x},${y}\],"
					if {$k == "rgb_bri"} {
						append json "\"bri\":${bri},"
					}
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
					append json "\"${k}\":\"${v}\","
				} else {
					set nm ""
					regexp {^(-?\d+)$} $v match nm
					if {$nm != "" || $v == "true" || $v == "false"} {
						append json "\"${k}\":${v},"
					} else {
						append json "\"${k}\":\"${v}\","
					}
				}
			}
		}
		
		if {[info exists env(CUXD_TRIGGER_CH)]} {
			set chan $env(CUXD_TRIGGER_CH)
			set key ""
			set val ""
			if {$chan == 1} {
				array set st [hue::get_object_state $bridge_id $obj_type $obj_id]
				if {[info exists env(CUXD_DEVICE)]} {
					set cuxd_device "CUxD.$env(CUXD_DEVICE)"
					hue::update_cuxd_device_channels $cuxd_device $st(reachable) $st(on) $st(bri) $st(ct) $st(hue) $st(sat)
				}
				return
			}
			set val $env(CUXD_VALUE${chan})
			if {$chan == 2} {
				set key "bri"
				# 0 - 254
				array set st {}
				if {$cmd == "group" || $bri_mode == "inc"} {
					array set st [hue::get_object_state $bridge_id $obj_type $obj_id]
				}
				if {[lsearch $keys "on"] == -1} {
					if {$val == 0} {
						append json "\"on\":false,"
					} else {
						if {$cmd == "light"} {
							append json "\"on\":true,"
						} elseif {$cmd == "group"} {
							if {$st(on) == "false"} {
								hue::write_log 4 "bri > 0, all lights off, auto turn on group"
								append json "\"on\":true,"
							}
						}
					}
				}
				if {$val > 0 && $bri_mode == "inc"} {
					set key "bri_inc"
					set bri $st(bri)
					if {$bri == ""} { set bri 0 }
					set val [expr {$val - $bri}]
				}
			} elseif {$chan == 3} {
				set val [expr {$val + $ct_min}]
				set key "ct"
				# mirek, range depends on device (i.e. 153 - 500)
			} elseif {$chan == 4} {
				set key "hue"
				# 0 - 65535
			} elseif {$chan == 5} {
				set key "sat"
				# 0 - 254
			}
			if {$key != "" && [lsearch $keys $key] == -1} {
				append json "\"${key}\":${val},"
			}
		}
		
		if {$json != "\{"} {
			set json [string range $json 0 end-1]
		}
		append json "\}"
		
		if {$sleep > 0} {
			hue::write_log 4 "Sleep ${sleep} ms"
			after $sleep
		}
		
		puts [hue::hued_command "api_request" [list "command" $bridge_id $cmd $num "PUT" $path $json]]
	}
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


