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

proc write_log {str} {
	set fd [open "/tmp/hue.log" "a"]
	puts $fd $str
	close $fd
}

proc usage {} {
	global argv0
	puts stderr ""
	puts stderr "usage: ${argv0} <bridge-id> <command>"
	puts stderr ""
	puts stderr "possible commands:"
	puts stderr "  request <method> <resource> \[data\]     send a request to rest api"
	puts stderr "    method   : one of GET,POST,PUT,DELETE"
	puts stderr "    resource : URL path"
	puts stderr "    data     : optional json data"
	puts stderr ""
	puts stderr "  light <light-id> \[parm:val\]...         control a light"
	puts stderr "    light-id : id of the light to control"
	puts stderr "    parm=val : parameter and value pairs separated by a colon"
	puts stderr "               some ot the possible paramers are: on,sat,bri,hue,xy,ct"
	puts stderr ""
	puts stderr "  group <group-id> \[parm:val\]...         control a group"
	puts stderr "    group-id : id of the group to control"
	puts stderr "    parm=val : parameter and value pairs separated by a colon"
	puts stderr "               some ot the possible paramers are: on,sat,bri,hue,xy,ct,scene"
}


proc main {} {
	global argc
	global argv
	global env
	
	set bridge_id [string tolower [lindex $argv 0]]
	set cmd [string tolower [lindex $argv 1]]
	
	if {$cmd == "request"} {
		if {$argc < 4} {
			usage
			exit 1
		}
		puts [hue::request $bridge_id [lindex $argv 2] [lindex $argv 3] [lindex $argv 4]]
	} else {
		if {$argc < 3} {
			usage
			exit 1
		}
		set path ""
		if {$cmd == "light"} {
			set path "lights/[lindex $argv 2]/state"
		} elseif {$cmd == "group"} {
			set path "groups/[lindex $argv 2]/action"
		} else {
			usage
			exit 1
		}
		set keys [list]
		set json "\{"
		foreach a [lrange $argv 2 end] {
			regexp {(.*)[=:](.*$)} $a match k v
			if {[info exists v]} {
				lappend keys k
				set nm ""
				regexp {^(\d+)$} $v match nm
				if {$nm != "" || $v == "true" || $v == "false"} {
					append json "\"${k}\":${v},"
				} else {
					append json "\"${k}\":\"${v}\","
				}
			}
		}
		
		if {[info exists env(CUXD_TRIGGER_CH)]} {
			set chan $env(CUXD_TRIGGER_CH)
			set key ""
			set val ""
			if {$chan == 1} {
				return
			} else {
				set val $env(CUXD_VALUE${chan})
			}
			if {$chan == 2} {
				set key "bri"
				# 0 - 254
			} elseif {$chan == 3} {
				set val [expr {$val + 153}]
				set key "ct"
				# 153 - 500 mirek
			} elseif {$chan == 4} {
				set key "hue"
				# 0 - 65535
			} elseif {$chan == 5} {
				set key "sat"
				# 0 - 254
			}
			if {$key && [lsearch $keys $key] == -1} {
				append json "\"${key}\":${val},"
			}
		}
		
		if {$json != "\{"} {
			set json [string range $json 0 end-1]
		}
		append json "\}"
		puts [hue::request $bridge_id "PUT" $path $json]
		
	}
}

if { [ catch {
	#catch {cd [file dirname [info script]]}
	main
} err ] } {
	puts stderr "ERROR: $err"
	exit 1
}
exit 0


