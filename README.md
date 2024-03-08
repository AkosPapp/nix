# My Custom NixOS Configuration

This configuration system is designed to be extremely modular and versatile, enabling its use across multiple systems without any modifications.

## Structure
The configuration is divided into several pieces:

### Modules
Custom NixOS modules that can enable various NixOS options. Each module can be enabled using the NixOS configuration syntax:
```nix
config.MODULES.<module-name>.enable = true;
```

### Users
Contains configurations for each user. Users can enable custom modules and modify NixOS options according to their preferences. Users can be enabled as follows:
```nix
config.USERS.<user-name>.enable = true;
```

### Profiles
Profiles allow combining multiple users or modules to streamline configurations. They can be enabled using the following syntax:
```nix
config.PROFILES.<profile-name>.enable = true;
```

### Hosts
Configuration for each physical machine, including hardware specifications. Host configurations can enable modules, users, and profiles as needed.

## Build System
A Makefile is utilized to simplify rebuilding, switching, and git operations. For assistance, run:
```bash
make help
```

