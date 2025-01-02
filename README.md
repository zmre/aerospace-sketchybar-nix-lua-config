# README

Full disclosure: I have no idea what I'm doing.

I'm messing with a sketchybar config inside a flake so I don't pollute my system config with experiments as I learn how to package up lua stuff.

My goal is to use Aerospace and Sketchybar together and they should really be packaged together so this may evolve.

At present, this requires fonts, but you can't just add fonts to a flake because they have to be installed on the system.  I'm playing with others' configs as starting points so I'm installing fonts they use. I had to install SF Pro and SF Mono by hand (ick) and I added sketchybar-app-font from nixpkgs to my system.

At present I tweak and test by doing:

`nix build && sketchybar -c result`

Ultimately I want this to be something I reference from my system config and it uses home manager to put some things in the right places there.
