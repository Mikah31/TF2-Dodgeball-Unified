#Supershot
Adds back the supershot feature from Dodgeball Redux, requires both the main and subplugin to be installed.

**Requires** modification of your dodgeball config, an example config utilizing supershot being:
```
"subplugins"
{
    "supershot"
    {
        "enabled"                      "1"            // Enables / disables supershot

        "alert sound all"            "0"            // Plays alert sound to all on supershot
        "dragging enabled"      "1"            // Dragging allowed after using supershot

        "warn target"                "1"            // Warn target if they are being locked (and do not have someone else locked)

        "speed multiplier"        "2.0"          // Multiplier on speed on supershot
        "turnrate multiplier"    "1.0"          // Multiplier on turnrate on supershot
    }
}
```