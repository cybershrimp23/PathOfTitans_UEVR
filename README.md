# Path of Titans VR Mod

## Introduction this is a VR Mod for the game Path Of Titans using UEVR

* This is very early on there are bugs
  * Known issues
    * Upon startup the VR view is not correct
    * Ability editor has flashing
    * Changes play dynamics
  * VR Experiance
    * Must disable anti-cheat, so limited to single player or servers where mods are allowed
    * Camera controller is still early on so it works, but could be better
    * No snap turning (So novice VR users may find it nausiating)
    * Does not use VR controllers so a game controller / keyboard \& mouse is required
    * Changes game play for better \& worse
      * Better: can see more pray, notice more in the environment
      * Worse: it may change fighting dynamics a bit - not sure here yet



## Getting started

* Download UEVR.zip from https://github.com/joeyhodge/UEVR/releases/tag/101226HELLRAISERp1

  * You may want to submit UEVR.zip to www.virustotal.com to make sure it's not malware - __you should be doing this with any game mod you download!__
* Unzip the UEVR.zip into a known location 
* Create a "scripts" folder inside the unzipped UEVR folder
* Download the script pot\_vrcamera.lua from this repo (click on the file and then click on raw) and place it in the scripts folder in the unzipped location of UEVR
* Start Path of Titans
* Disable anti cheat under Settings -> Game (gear in the upper right in the launcher next to your user name)

  * **This will make it so that you cannot join many servers and will require playing in single player mode or servers which allow anti-cheat to be disabled**
* If you have a wide screen monitor you will likely want to set the game to windowed mode in 1920x1080 so that the in game overlay shows up correctly, it's size is set based upon your monitor size.
* Start the game from the launcher and enter the world using the dinosaur you want to play
* Run UEVRInjector.exe
* In UEVR click run as administrator
* Then choose Path of Titans from the options and click 'Inject'
  * If you have issues you may need to try OpenXR otherwise it seems to work fine for me in OpenVR
* Wait about 30 seconds for everything to start working
* The first time the game shows up in VR you'll see the UEVR control panel (hit insert key to hide/show it)

  * There is a bug which causes the game to have incorrect camera angles, click "Reinitialize Runtime" in the UEVR gui in VR or put on the headset once, then set it down so it switches back to 2D mode and then put it on again, this will get it working correctly. 
* Enjoy Path of Titans in VR!

## Advanced

* In the UEVR GUI there is a tab called PoT VR Camera this will let you play with some of the settings I've tweaked

* Here are things I've tried and learned
  * Ambient Occlusion must be set to LumenAO or disabled otherwise you'll get shimmering
    * It doesn't matter if you use Native Stereo or Synchronized Sequential, the AO causes problems
* You may need to turn down your VR resolution, PoT can be pretty GPU intensive
* I tried using AI to fix the initial startup issue, and couldn'get it to work, it's a minor annoyance
* In the UEVR GUI 
    * Under Camera -> Match Game FOV this is enabled it seems to work for me but if stuff in 3D doesn't quite line up for you try toggling it. 
    * Under Runtime -> Overlay options you may want to move the overlay to a better location


