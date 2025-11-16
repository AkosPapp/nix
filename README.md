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

Here's a comparison table showing how each solution aligns with your key requirements. Entries are rated as:

* ✅ Fully supported / well suited
* ⚠️ Partially supported or needs workarounds
* ❌ Not supported or impractical

| Solution                 | Multi-Machine   | NixOS Compatible  | Offline Editing | Selective Folder Sync | Auto Folder Discovery | Force Full Copy on Host | Snapshots/Versioning | Large Files (10GB) | Dedup/COW Support   | Fast Change Detection | Open Source | Ease of Setup |
| ------------------------ | --------------- | ----------------- | --------------- | --------------------- | --------------------- | ----------------------- | -------------------- | ------------------ | ------------------- | --------------------- | ----------- | ------------- |
| **Git + Sparse/Partial** | ✅               | ✅                 | ✅               | ⚠️ (Manual setup)     | ❌                     | ⚠️ (Clone all manually) | ✅ (via commits)      | ⚠️ (with LFS)      | ❌ (LFS is separate) | ❌ (Scan needed)       | ✅           | ⚠️            |
| **Git LFS**              | ✅               | ✅                 | ⚠️ (LFS fetch)  | ⚠️ (Manual)           | ❌                     | ⚠️                      | ✅ (Git history)      | ✅                  | ❌                   | ❌                     | ✅           | ⚠️            |
| **Git-Annex**            | ✅               | ✅                 | ✅               | ✅                     | ❌                     | ✅ (via `get --all`)     | ✅                    | ✅                  | ✅ (hash-based)      | ❌ (Scan Git tree)     | ✅           | ❌ (complex)   |
| **Jujutsu (jj)**         | ✅               | ✅                 | ✅               | ⚠️ (Manual)           | ❌                     | ⚠️                      | ✅                    | ❌                  | ❌                   | ❌                     | ✅           | ⚠️ (new tool) |
| **Watchman + Git**       | ✅               | ✅                 | ✅               | ⚠️                    | ❌                     | ⚠️                      | ✅ (Git)              | ❌                  | ❌                   | ✅                     | ✅           | ⚠️            |
| **Automerge/Yjs**        | ❌ (not FS)      | ✅                 | ✅               | ❌ (Not file-based)    | ❌                     | ❌                       | ✅ (internal)         | ❌                  | ❌                   | ✅                     | ✅           | ❌ (dev work)  |
| **Perkeep**              | ✅               | ⚠️ (not packaged) | ✅               | ✅                     | ✅ (query-based)       | ✅                       | ✅                    | ✅                  | ✅                   | ✅ (hash-indexed)      | ✅           | ❌ (complex)   |
| **Restic + FUSE**        | ✅               | ✅                 | ✅               | ✅                     | ❌                     | ✅ (via restore)         | ✅                    | ✅                  | ✅                   | ⚠️ (scan on backup)   | ✅           | ⚠️            |
| **Unison**               | ⚠️ (pairs only) | ✅                 | ✅               | ✅                     | ❌                     | ✅                       | ❌ (no history)       | ✅                  | ❌                   | ✅                     | ✅           | ⚠️ (manual)   |
| **Ceph**                 | ✅               | ⚠️ (heavy setup)  | ❌               | ❌                     | ❌                     | ✅ (all data)            | ✅                    | ✅                  | ⚠️                  | ✅                     | ✅           | ❌             |
| **GlusterFS**            | ✅               | ⚠️                | ❌               | ❌                     | ❌                     | ✅                       | ⚠️ (external)        | ✅                  | ❌                   | ✅                     | ✅           | ❌             |
| **ZFS**                  | ✅ (1-way)       | ✅                 | ⚠️              | ⚠️ (Dataset-level)    | ❌                     | ✅                       | ✅                    | ✅                  | ✅                   | ⚠️ (cron or events)   | ✅           | ⚠️ (manual)   |
| **Btrfs**                | ✅ (1-way)       | ✅                 | ⚠️              | ⚠️                    | ❌                     | ✅                       | ✅                    | ✅                  | ⚠️ (manual dedup)   | ⚠️                    | ✅           | ⚠️            |
| **Syncthing**            | ✅               | ✅                 | ✅               | ✅                     | ❌                     | ✅                       | ⚠️ (limited)         | ✅                  | ❌                   | ✅                     | ✅           | ✅             |

Let me know if you want a version of this as a CSV or need help designing a hybrid setup from the best components.
Here's a comparison table showing how each solution aligns with your key requirements. Entries are rated as:

* ✅ Fully supported / well suited
* ⚠️ Partially supported or needs workarounds
* ❌ Not supported or impractical

| Solution                 | Multi-Machine   | NixOS Compatible  | Offline Editing | Selective Folder Sync | Auto Folder Discovery | Force Full Copy on Host | Snapshots/Versioning | Large Files (10GB) | Dedup/COW Support   | Fast Change Detection | Open Source | Ease of Setup |
| ------------------------ | --------------- | ----------------- | --------------- | --------------------- | --------------------- | ----------------------- | -------------------- | ------------------ | ------------------- | --------------------- | ----------- | ------------- |
| **Git + Sparse/Partial** | ✅               | ✅                 | ✅               | ⚠️ (Manual setup)     | ❌                     | ⚠️ (Clone all manually) | ✅ (via commits)      | ⚠️ (with LFS)      | ❌ (LFS is separate) | ❌ (Scan needed)       | ✅           | ⚠️            |
| **Git LFS**              | ✅               | ✅                 | ⚠️ (LFS fetch)  | ⚠️ (Manual)           | ❌                     | ⚠️                      | ✅ (Git history)      | ✅                  | ❌                   | ❌                     | ✅           | ⚠️            |
| **Git-Annex**            | ✅               | ✅                 | ✅               | ✅                     | ❌                     | ✅ (via `get --all`)     | ✅                    | ✅                  | ✅ (hash-based)      | ❌ (Scan Git tree)     | ✅           | ❌ (complex)   |
| **Jujutsu (jj)**         | ✅               | ✅                 | ✅               | ⚠️ (Manual)           | ❌                     | ⚠️                      | ✅                    | ❌                  | ❌                   | ❌                     | ✅           | ⚠️ (new tool) |
| **Watchman + Git**       | ✅               | ✅                 | ✅               | ⚠️                    | ❌                     | ⚠️                      | ✅ (Git)              | ❌                  | ❌                   | ✅                     | ✅           | ⚠️            |
| **Automerge/Yjs**        | ❌ (not FS)      | ✅                 | ✅               | ❌ (Not file-based)    | ❌                     | ❌                       | ✅ (internal)         | ❌                  | ❌                   | ✅                     | ✅           | ❌ (dev work)  |
| **Perkeep**              | ✅               | ⚠️ (not packaged) | ✅               | ✅                     | ✅ (query-based)       | ✅                       | ✅                    | ✅                  | ✅                   | ✅ (hash-indexed)      | ✅           | ❌ (complex)   |
| **Restic + FUSE**        | ✅               | ✅                 | ✅               | ✅                     | ❌                     | ✅ (via restore)         | ✅                    | ✅                  | ✅                   | ⚠️ (scan on backup)   | ✅           | ⚠️            |
| **Unison**               | ⚠️ (pairs only) | ✅                 | ✅               | ✅                     | ❌                     | ✅                       | ❌ (no history)       | ✅                  | ❌                   | ✅                     | ✅           | ⚠️ (manual)   |
| **Ceph**                 | ✅               | ⚠️ (heavy setup)  | ❌               | ❌                     | ❌                     | ✅ (all data)            | ✅                    | ✅                  | ⚠️                  | ✅                     | ✅           | ❌             |
| **GlusterFS**            | ✅               | ⚠️                | ❌               | ❌                     | ❌                     | ✅                       | ⚠️ (external)        | ✅                  | ❌                   | ✅                     | ✅           | ❌             |
| **ZFS**                  | ✅ (1-way)       | ✅                 | ⚠️              | ⚠️ (Dataset-level)    | ❌                     | ✅                       | ✅                    | ✅                  | ✅                   | ⚠️ (cron or events)   | ✅           | ⚠️ (manual)   |
| **Btrfs**                | ✅ (1-way)       | ✅                 | ⚠️              | ⚠️                    | ❌                     | ✅                       | ✅                    | ✅                  | ⚠️ (manual dedup)   | ⚠️                    | ✅           | ⚠️            |
| **Syncthing**            | ✅               | ✅                 | ✅               | ✅                     | ❌                     | ✅                       | ⚠️ (limited)         | ✅                  | ❌                   | ✅                     | ✅           | ✅             |

Let me know if you want a version of this as a CSV or need help designing a hybrid setup from the best components.
