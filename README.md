# HomeMatic addon to control Philips Hue Lighting

## Prerequisites
* This addon depends on CUxD

## Installation / configuration
* Download [addon package](https://github.com/j-a-n/homematic-addon-lgtv/raw/master/hm-hue.tar.gz)
* Install addon package on ccu via system control
* Open Philips Hue addon configuration in system control and add your Hue Bridges
* Create new device in CUxD
* Configure new device in HomeMatic Web-UI
* Configure a device channel for each TV and command you want to use
 * Select CMD_EXEC
 * Set CMD_SHORT to `/usr/local/addons/hue/hue.tcl <bridge-id> <command>` (see usage for details)

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
`usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 on=true sat=200 hue=1000 bri=100`

Turn on light 1 and set saturation, hue and brightness:  
`usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 on=true sat=200 hue=1000 bri=100`

Set color temperature of light 1 to 500 with a transition time of 1 second (10 * 1/10s):  
`usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 ct=500 transitiontime=10`

Start colorloop effect on light 2:  
`usr/local/addons/hue/hue.tcl 0234faae189721011 light 2 effect=colorloop`

Flash group 1 once:  
`usr/local/addons/hue/hue.tcl 0234faae189721011 group alert=select`

Flash group 1 repeatedly:  
`usr/local/addons/hue/hue.tcl 0234faae189721011 group alert=lselect`

Set scene for light group 1:  
`usr/local/addons/hue/hue.tcl 0234faae189721011 group 1 scene=AY-ots9YVHmAE1f`
