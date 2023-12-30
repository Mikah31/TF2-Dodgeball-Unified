# TF2-Dodgeball-Unified
This is a TF2 Dodgeball plugin which unifies many subplugins and some server-specific features into 1 plugin amongst other changes whilst removing some lesser used features.

# Requirements
- [CFGmap](https://forums.alliedmods.net/showthread.php?t=319763) (Compile only).
- [Multi-colors](https://forums.alliedmods.net/showthread.php?t=185016) (Compile only).
- [TF2 Attributes](https://forums.alliedmods.net/showthread.php?t=210221) (Requires tf2attributes.smx)

# Installation
Copy the contents of `TF2DodgeballUnified` inside of `tf`. This plugin is NOT compatible with any subplugins made specifically for dodgeball plugins.

# Removed features (as of now, these could be added later)
- Multiple types of rockets with spawning chances within 1 config.
- The ability to make subplugins using natives.
- FFA / Hitting team rockets do not automatically disable once it is player vs bot, some bots break whenever FFA or team airblast rockets are enabled.
- Taunt killing has not been disabled.
- Nukes are completely removed.

# Added features
- Maximum rocket velocity has been uncapped. (in dodgeball_enable.cfg, setup time & round ending time are also reduced by default now)
- Rocket speed, turnrate and damage are now governed by formula's.
- Configs can be loaded more easily from within the game. ("sm_loadconfig")
- More wavetypes have been added aside from vertical waves. (horizontal & circular)
- Bouncetypes have been seperated. (downspiking and elastic bounces)
- The rocket will not wave whilst within orbitting range.
- A push scale has been introduced to airblast players further away. (if airblasting players is enabled)
- Airblast delay can now be changed in the config. (Taken from Swagville).
- Never ending rounds. (Taken from Crimson Dynasty)

# Changed features
- Wave has been remade using trigonometric functions, classic/vertical waves have been remade (it might not be exactly the same).
- Dodgeball config handling & layout has been changed. (They are not compatible with previous plugins)
- Translations has slightly been altered for consistency. (They are not compatible with previous plugins)
- Many subplugins have been integrated into the main plugin. (Speedometer, Airblast prevention, Anti snipe, No blocking, Free for all, Never ending rounds)
- Rockets are now struct enums, which should help creating subplugins. (for the future)
- Delay time now only increases whilst in orbitting range.
- Bounce time (when downspiking) has been added instead of scaling the bounce vector, this can be used to create bigger (or smaller) bounces.

# Commands
- **sm_loadconfig** (*config.cfg*) : Loads specified config file, if no config file specified will load "general.cfg". (config must be within "addons/sourcemod/configs/dodgeball" directory)
- **sm_ffa** : Forces toggling of FFA mode if config allows it.
- **sm_voteffa** : Starts a vote for toggling FFA.
- **sm_ner** : Forces toggling of NER mode.
- **sm_votener** : Starts a vote for toggling NER mode.

# Config items overview
```
// Rockets
  "damage formula"

  "speed formula"
  "minimum speed"
  "maximum speed"

  "turnrate formula"
  "minimum turnrate"
  "maximum turnrate"

  "drag time min" // Also selects target after this time
  "drag time max"

  "max bounces"
  "down spiking" // 1 -> Downspiking, 0 -> elastic bouncing
  "bounce time" // Lower bounce time creates smaller, but more spikes and vice versa

  "wave type" // 3 wavetypes: 0 -> disabled, 1 -> vertical, 2-> horizontal, 3-> circular
  "wave oscillations" // Number of half periods of the wave: θ = nπ, where 'n' is wave oscillations
  "wave amplitude"

// General gameplay
  "max rockets"
  "rocket spawn interval"

  "max steals"
  "stolen rockets do damage"

  "airblast push prevention"
  "airblast push scale"

  "disable player collisions"

  "airblast delay"
  "airblastable team rockets" // This can break some bots, same goes for if FFA is enabled

  "delay time"

  "free for all" // Enables the ability for the activation of FFA, same goes for NER
  "ffa voting timeout"

  "never ending rounds"
  "ner voting timeout"

  "rocket speedometer"
```
A more detailed explanation is given in the supplied config "general.cfg".

# Credits
1. This plugin is mainly based off of a modified version of YADP modified by x07x08, Silorak & Tolfx, many subplugins from there were also integrated into this plugin. | [Link](https://github.com/x07x08/TF2-Dodgeball-Modified/)
2. The original YADB plugin by Damizean. | [Link](https://forums.alliedmods.net/showthread.php?t=134503)
