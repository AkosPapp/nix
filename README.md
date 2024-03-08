# My Custom Nixos Configuration
this configurations system is designed to be extreamly modular.
it is meant to be used on multiple systems without any modification.

## Structure
the config is split up into multiple peaces
### Modules
custom nixos modules that can enable any nixos options.
any module can be enabled with the nixos config: `config.MODULES.<module mane>.enable = true;`
### Users
contains configurations for every user.
each user can enable custom modules and change and nixos option.
users can be enabled with `config.USERS.<user name>.enable = true;`
### Profiles
can combine multiple Users or Modules to make configurations easier.
profiles can be enable with `config.PROFILES.<profile name>.enable = true;`
### Hosts
configuration for every phisical machiene.
contains hardware configuration and can enable Modules, Users and Profiles

## Build System
a Makefile is used to simplify rebuilding, switching and git operations.
run `make help` for help

`

