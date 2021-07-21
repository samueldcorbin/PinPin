# PinPin

Adds chat commands for in-game map pins that are easily shareable with other players.

* Familiar syntax. The basic **/way** command uses the same form as TomTom (meaning existing waypoint coordinates on the internet will work just fine).\*

* Share map pins even with people, even if they don't have any addons installed.

* Toggle-able enhancements to the default map pin system:

  * Better map pin tooltips
  
  * Allow map pins in more areas (can still be shared with people without the addon even for some places they can't place these pins themselves!)

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

All enhancements to the default pin system can be toggled on or off individually, and the command prefix (default **/way**) is also customizable, enabling it to play nice with other addons.

Future plans include the ability to import and view multiple map pins simultaneously.

\* The map naming scheme (e.g., "Nagrand:Outlands") is similar to TomTom, but a few map names may differ.
