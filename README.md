# README

## Goal

My goal with this repo is to use Aerospace and Sketchybar together where their configs and versions are interdependent and I want reproducible working setups.  I want the sketchybar setup to be reasonably fast so I want it to use the lua interface instead of the bash madness.  And I want the whole mess to be largely outside of my system files so as not to overly pollute my already complicated setup [there](https://github.com/zmre/nix-config).

## Starting Point

To start with, I'm using the [creator of Sketchybar's dotfiles](https://github.com/FelixKratz/dotfiles/tree/e27673f07ff41eb6a4816daabb79b0a5e837a105/.config/sketchybar), `FelixKratz`, as my config, but he uses yabai and isn't in nix-land, so I'm switching yabai for Aerospace and packaging it all.  The major change to his configs are just the addition of `aerospace.lua` as an alternative to `spaces.lua`.

## Disclaimer

Full disclosure: I have no idea what I'm doing.

I'm learning sketchybar stuff, how to package lua in nix, how to combine these things, and I think I'm doing it all with near zero elegance at this point.  I hope that will evolve as I understand better what's happening.

I'm messing with a sketchybar config inside a flake so I don't pollute my system config with experiments as I learn how to package up lua stuff.

The current nix packaging is poor.  I'd rather do a symlinkjoin or a single repo or something. Worse, I just compiled some of the C sub-utilities (like for getting CPU usage) and committed them back to the repo and copy them in, which is the ultimate lazy and awful approach.  That needs to change, but also I need to figure out if there's a way to get updates upstream for those in case he fixes bugs in them.

Regardless of the lazy shortcuts as I try to make things work, the duct tape is holding for now and pressure to make it nicer is pretty low.

## Using the Setup

Sadly, though I wanted this to be a nice stand-alone flake, it has dependencies that can't be installed via flakes: namely fonts.  You're going to need to install SF Pro and SF Mono and maybe alternately some nerdfonts. I installed the SF fonts via homebrew:

```
      "font-sf-pro"
      "font-sf-mono-for-powerline"
      "font-sf"
      "sf-symbols"
```

That last `sf-symbols` cask is actually a GUI for browsing symbols.  You also need `pkgs.sketchybar-app-font` for the app icons, but I think the dependencies in the flake are good enough.  If you get bogus stuff there, you might need to install that in the system config. If so, let me know so I can update this readme.

At present I tweak and test by cloning this repo and then just locally doing:

`nix run`

That will kill off any running processes and start them back up fresh with new configs. It holds the apps in the foreground and print statements go to the console.  I'll add directions for how to include this from your system config later.


## TODO

### Flake

* [ ] I'd rather rejigger this whole thing so that I make a customer Aerospace and use makeBinaryWrapper to bring in all my dependencies and paths and such.  Then aerospace could just be launched as normal and configs and such all just ride along, which would make things way easier.
  * [ ] While I'm at it, I'd like to think about some symlinkjoin stuff so a built folder has everything in it in one place
* [ ] Change build stuff so the sketchybar compiled C files are actually compiled instead of being checked in as binaries

### Sketchybar

* [ ] I think we need to store state and maybe monitor more events such as aerospace on-focused-monitor-change and/or sketchybar space_change or display_change all of which should trigger on the same thing in our case 
  * Using state, we could track active workspace on each display to fix bugs there and we can probably do better at tracking when workspaces move between displays. display_woke and system_woke might be good times to re-init Annoyingly will need to track the global previous workspace and the per-display active workspace and then once those globals have been updated, run through and get the highlights correct on everything
* [ ] Bugs when the menus are toggled in and then workspaces are changed. 
  * Need a var that tracks display state so if workspace display is off, we don't accidentally start redrawing stuff in piecemeal
* [ ] If there's a display that doesn't have an app on it, the bar doesn't show what workspace is there. Need to show empty workspaces that are active on displays
* [ ] Moving a workspace to a different screen doesn't trigger any sort of update right now. Maybe the events above?
* [ ] the sketchybar-app-fonts are great for many apps, but I keep finding ones that are missing (eg, Photos, Ghostty, etc) so is there a way for me to use icons from elsewhere if the repo doesn't support something?  
  * Or do I need a fork and to make my own icons?  I've seen PRs that are languishing and will need to see if that continues. Update: I submitted a PR that's languishing
* [ ] Bug: screens sometimes jumbled so the B workspace is on my left and shows in sketchy like it's on the right 
  * See: https://github.com/nikitabobko/AeroSpace/issues/336 
  * It appears that sketchybar is using a private API with unknown ordering that's not compatible public API or Aerospace. But sometimes lines up with NSScreens. Ugh. 
  * I don't see any way to fix this. It changes. Sketchy doesn't allow addressing via name or left-to-right order or anything. Fix: best I can do is let it assign and if I detect it's wrong, press a hotkey to send an event that swaps them. 1 will likely always be right.
* [ ] When disconnecting from external monitors and then waking from sleep, sketchybar flashes and changes and flashes and changes quite a bit. 
  * At the same time, aerospace is jumping things around, which may be part of it, but I suspect multiple different events are triggering refreshes.  
  * Perhaps each monitor removal (I have 3 external) is its own event, for example. 
    * How can I avoid the flickering and ideally avoid unnecessary work?  I almost need a debounce or something or a way to update the stored state and compare it to the displayed state.  Or really to see if any changes are needed to the stored state and only go through display updates when there are changes.  So maybe two phases: phase 1 is update state, phase 2 executes if changes were made to state and updates display items.
