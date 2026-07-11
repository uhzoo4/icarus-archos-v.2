# Curated applications

Icarus uses [Awesome Linux Software](https://github.com/luong-komorebi/Awesome-Linux-Software)
as a discovery source for its opt-in application profiles. The upstream work
is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
The upstream repository was archived in May 2026, so it is a static curation
source rather than a live recommendation feed. Package names are therefore
kept against Arch's current official repositories when Icarus profiles change.

This repository does not vendor the upstream catalogue or its icons. Instead,
it installs a small selection during Layer 9, using packages from Arch's
official repositories only. The default selection is `essentials sharing`, so
the completed Icarus system has those apps on its first boot. Change
`configs/apps/profiles.conf` before assembling, or override it per run:

```bash
./icarus-assemble.sh --target /dev/sdX --app-profiles "development gaming"
```

After boot, `icarus-apps list` and `icarus-apps install PROFILE` remain
available for adding further profiles.

The individual projects retain their own licenses and are supplied by Arch
Linux packages; installing a profile does not make Icarus a distributor of
their upstream source code.
