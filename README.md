# HomeMatic addon to control Philips Hue Lighting

## Prerequisites
* This addon depends on CUxD

## Installation / configuration
* Download [addon package](https://github.com/j-a-n/homematic-addon-hue/raw/master/hm-hue.tar.gz)
* Install addon package on ccu via system control
* Open Philips Hue addon configuration in system control and add your Hue Bridges (http://ccu-ip/addons/hue/index.html)

### Multi-DIM-Device
* Create new (28) System device in CUxD for each group or light
  * Function: Multi-DIM-Exec
  * Serialnumber: choose a free one
  * Name: choose one, i.e: `Hue Group 1`
  * Device-Icon: whatever you want
* Configure new device in HomeMatic Web-UI
  * Channels: 4
  * CMD_EXEC: `/usr/local/addons/hue/hue.tcl <bridge-id> group 1 transitiontime:0` (see usage for details)
  * Ch.2 (brightness): DIMMER|MAX_VAL: 254
  * Ch.3 (color temperature): DIMMER|MAX_VAL: 347
  * Ch.4 (hue): DIMMER|MAX_VAL: 65535
  * Ch.5 (saturation): DIMMER|MAX_VAL: 254

### Universal-Control-Device
* Create new (40) 16-channel universal control device in CUxD
  * Serialnumber: choose a free one
  * Name: choose one, i.e: `Hue`
  * Device-Icon: whatever you want
  * Control: KEY
* Configure new device in HomeMatic Web-UI
  * CMD_EXEC: yes
  * CMD_SHORT `/usr/local/addons/hue/hue.tcl <bridge-id> <command>`

## hue.tcl usage
`/usr/local/addons/hue/hue.tcl <bridge-id> <command>`

### bridge-id
The bridge-id is displayed on the addon's system control

### Commands

command        | description
---------------| -----------------------------
`request`      | send a request to rest api
`light`        | control a light
`group`        | control a group

The `request` command can be use to send a raw api request.
[Philips Hue API documentation](https://developers.meethue.com/philips-hue-api).

### Examples
Turn on light 1 and set saturation, hue and brightness:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 on:true hue:1000 sat:200 bri:100`

Turn light 1 off:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 on:false`

Set color temperature of light 1 to 500 with a transition time of 1 second (10 * 1/10s):  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 ct:500 transitiontime:10`

Start colorloop effect on light 2:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 2 effect:colorloop`

Stop effect on light 2:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 2 effect:none`

Flash group 1 once:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 group 1 alert:select`

Flash group 1 repeatedly:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 group 1 alert:lselect`

Set scene for light group 1:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 group 1 scene:AY-ots9YVHmAE1f`

Get configuration items:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET config`

Get info about connected lights:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET lights`

Get configured groups:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET groups`

Get configured scenes:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET scenes`

Turn off light 2:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request PUT lights/2/state '{"on":false}'`

