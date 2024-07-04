# TF2-Dodgeball-Unified
This is a TF2 Dodgeball plugin which unifies many subplugins and some server-specific features into 1 plugin amongst other changes whilst removing some lesser used features.

# Requirements
- [CFGmap](https://forums.alliedmods.net/showthread.php?t=319763) (Compile only).
- [Multi-colors](https://forums.alliedmods.net/showthread.php?t=185016) (Compile only).
- [TF2 Attributes](https://forums.alliedmods.net/showthread.php?t=210221) (Requires tf2attributes.smx)

# Installation
Copy the contents of `TF2DodgeballUnified` inside of `tf`.

# Removed features (as of now, these could be added later)
- Multiple types of rockets with spawning chances within 1 config.
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
- Never ending rounds. (Taken from Crimson Dynasty).
- Added mid-air spiking.
- Added soft antisteal

# Changed features
- Wave has been remade using trigonometric functions, classic/vertical waves have been remade (it might not be exactly the same).
- Dodgeball config handling & layout has been changed. (They are not compatible with previous plugins)
- Translations has slightly been altered for consistency. (They are not compatible with previous plugins)
- Many subplugins have been integrated into the main plugin. (Speedometer, Airblast prevention, solo, Free for all, Never ending rounds)
- Rockets are now struct enums, which should help creating subplugins.
- Delay time now only increases whilst in orbitting range.
- Bounce time (when downspiking) has been added instead of scaling the bounce vector, this can be used to create bigger (or smaller) bounces.
- Reworked subplugin support, uses rocket & config structures

# Commands
- **sm_loadconfig** (*config.cfg*) : Loads specified config file, if no config file specified will load "general.cfg". (config must be within "addons/sourcemod/configs/dodgeball" directory)
- **sm_ffa** : Forces toggling of FFA mode if config allows it.
- **sm_voteffa** : Starts a vote for toggling FFA.
- **sm_ner** : Forces toggling of NER mode.
- **sm_votener** : Starts a vote for toggling NER mode.
- **sm_solo** : Spawn player at the end of the round.

# Convars
```ini
  NER_volume_level "0.75" - Volume level of the horn played when respawning players
```
# Credits
1. This plugin is mainly based off of a modified version of YADP modified by x07x08, Silorak & Tolfx, many subplugins from there were also integrated into this plugin. | [Link](https://github.com/x07x08/TF2-Dodgeball-Modified/)
2. The original YADB plugin by Damizean. | [Link](https://forums.alliedmods.net/showthread.php?t=134503)
