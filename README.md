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


