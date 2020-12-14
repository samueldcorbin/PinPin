# PinPin

Adds chat commands for in-game map pins that are easily shareable with other players.

* Familiar syntax. The basic **/way** command uses the same form as TomTom (meaning existing waypoint coordinates on the internet will work just fine).

* Share map pins even with people, even if they don't have any addons installed.

* Toggle-able enhancements to the default map pin system:

  * Better map pin tooltips
  
  * Allow map pins in more areas (can still be shared with people without the addon even though they can't place these pins themselves!)

  * Configurable (including unlimited) distance for map pin visibility
  
  * Remember your map pins when logging out
  
  * Keep a map pin history (including across sessions)
  
  * Clear map pin on arrival
  
  * Etc.

* Useful additional commands, like **/wayt[arget]**, which puts a map pin to your current target into chat along with their name and current health.

  * A ping is fading and you still can't figure out where they were telling you to look? **/wayp[ing]** will put a map pin at the location of the last ping you saw on your minimap.
  
  * Etc.

* Lightweight

* No dependencies
  
  * Future-proof: Aside from Blizzard API changes, does not rely on anyone to keep libraries updated or to do manual data entry.

Also includes several optional enhancements to the default map pin system, adding better tooltips, customizable minimum and maximum (including unlimited) distance for map pin visibility, the ability to keep your map pin when you log out, a map pin history (optionally persistent across logins), the ability to automatically track newly-placed pins (automatically, or when you're not already tracking something else), automatically clearing pins on arrival, etc.

All enhancements to the default pin system can be toggled on or off individually, and the command prefix (default **/way**) is also customizable, enabling it to play nice with other addons.

One small caveat: Blizzard has limited which kinds of maps can take map pins. Most of the maps that you can't place pins on don't work in other addons either, but there are some that do work in other addons, and don't work with this (or with the built-in map pins in general). Nearly all of the maps you're likely to care about, however, work just fine.

Future plans include the ability to import and view multiple map pins simultaneously.
