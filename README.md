# HomeMatic addon to control Philips Hue Lighting

## DISCONTINUED
This repository is DISCONTINUED.
Since I have changed my own environment to Home Assistant and ZHA, I currently have no possibility to further develop or maintain this addon.
I only run a CCU instance as an addon in Home Assistant.

## Prerequisites
* This addon depends on CUxD

## Installation / configuration
* Download [addon package](https://github.com/j-a-n/homematic-addon-hue/raw/master/hm-hue.tar.gz)
* Install addon package on ccu via system control
* Open Philips Hue addon configuration in system control and add your Hue Bridges (http://ccu-ip/addons/hue/index.html)
* Set a poll interval if you want to frequently update the state of the CUxD devices with the state from your hue bridge.
* Click the bridge info button to see the list of lights, groups and scenes.
* Click on Create `CUxD-Dimmmer` or `Create CUxD-Switch` to create a new device.
* Go to the device inbox in HomeMatic Web-UI to complete the device configuration.

### Multi-DIM-Device (28)
You can add the parameter `bri_mode:inc` to the command.
This will keep the brightness difference of the lights in the group when using the dimmer.

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

You can add the parameter `sleep:<ms>` to delay light and group command for the given milliseconds.


### Examples
Turn on light 1 and set saturation, hue and brightness:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 on:true hue:1000 sat:200 bri:100`

Increase brightness of light 1 by 20, decrease saturation by 10:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 bri_inc:20 sat_inc:-10`

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

