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

puts "Content-Type: text/plain"

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
	if {![check_session $sid]} {
		puts "Status: 401 Unauthorized";
		puts ""
		puts "Invalid session"
	} else {
		puts "Status: 200 OK";
		puts ""
		puts -nonewline [hue::get_debug_data]
	}
} else {
	puts "Status: 401 Unauthorized";
	puts ""
	puts "Invalid session"
}

