# kconfig — kernel configuration files

This directory holds the kernel configuration inputs for the P03 kernel
build (see `sources/kernel-p03/kernel-p03.spec`).

| file | role |
|---|---|
| `linux-p03.config` | The upstream P03 tuning fragment. Merged on top of the distro base config by `merge_config.sh -m .config linux-p03.config` during the spec's `%prep`. Do not edit locally — track upstream. |
| `minimal-kernel.config` | Complete base `.config` produced from the running system (`make localmodconfig`, CachyOS-hardened lineage, Linux/x86 6.19.12 stamp). Skeleton for the machine-tailored build: boot-critical drivers built in, module set stripped to almost nothing. |
| `final-kernel.config` | **The kernel config for this machine** (i9-13900K, MSI Z790, RTX 2080 Ti, AX211, I225-V, NVMe×2, btrfs+LUKS, zram). Built by `generate-final-config.sh`; committed so the exact generated output is reviewable. |
| `generate-final-config.sh` | Reproduces `final-kernel.config` from the inputs above + the live `lsmod` snapshot. |
| `lsmod.snapshot` | Modules loaded when the config was last generated. |

## Module policy

`final-kernel.config` is built so that `=m` (loadable modules) is **only**
set for:

1. **Active modules** — everything loaded on this machine at generation
   time (mapped from the live `lsmod` snapshot to `CONFIG_*` symbols via the
   kernel's own `streamline_config.pl` against the running kernel's config,
   then re-resolved on the patched p03 tree — 202 symbols).
2. **Dependency closure** — rows the active modules select or depend on in
   the p03 tree (CROS_EC family behind HDMI CEC, NVMe fabrics/auth, vfio
   for the iGPU stack, regmap/transport helpers) plus selects the kernel
   enforces itself — all traceable, none optional.
3. **Gaming / handheld modules from `linux-p03.config`** — the Steam Deck /
   ROG Ally / Legion Go / MSI Claw / ZOTAC Zone / AYN set, kept as `=m`
   even though this desktop has none of that hardware.
4. **Future-proofing modules** — a small curated list this machine may
   plausibly need later (exFAT/NTFS3/SQUASHFS/ISO9660/CIFS/WireGuard, extra
   USB-UART adapter drivers, Xbox/Switch/PS controllers). These are `=m`
   **and** carry a `# TODO:` comment in the `.config`.

Everything else is built in (`=y`: core, boot-critical stack, and the p03
feature options) or off (`=n`: the upstream fragment's driver bloat). The
boot-critical stack stays built-in: NVMe core + device, btrfs, USB storage,
FAT/MSDOS/VFAT, SATA AHCI — a broken or mismatched initramfs still reaches
the LUKS+btrfs root.

p03 features intact as built-ins: `SCHED_ALT`/`SCHED_BMQ` (Project-C),
`PREEMPT_LAZY`, `MQ_IOSCHED_ADIOS` + default, `LRU_MARIE`, `VHBA`,
`CPU_IDLE_GOV_NAP`, `NFT_FULLCONE` (`=m`), BBRv3+FQ, Rust (no BTF), MLDSA
module-signing keys, the secureboot/IMA block, ThinLTO + Polly, HZ 750,
x86-64-v3.

Three deliberate deviations, documented inline:

* `HID_MSI_CLAW` doesn't exist in the 7.2 tree — the tree's `HID_MSI` *is*
  the MSI Claw driver. Stale fragment symbol dropped.
* Kconfig renames vs. this system's old 6.19 stamp: the `thunderbolt`
  module is `CONFIG_USB4`, `nct6683` is `CONFIG_SENSORS_NCT6683` — the
  whitelist uses their 7.2 names.
* The LSM default follows the fragment (`selinux`), while the live system
  runs AppArmor (`/sys/kernel/security/lsm` is apparmor-first). Flip
  `CONFIG_DEFAULT_SECURITY_*` and the `CONFIG_LSM=` order in one edit if
  you want AppArmor back.

## Regenerate

```bash
# from the repo root
bash sources/kconfig/generate-final-config.sh
# optional: --workdir DIR (default /tmp/opencode-p03-config), --version 7.2.6
```

The script needs network on first run (fetches the vanilla kernel tarball),
after that it reuses the workdir. It requires:

* `patch` (applies the P03 patchset), `make`, a C compiler for `conf`,
* `kernel-devel` installed for the running kernel (its `.config` is the
  symbol oracle; module names are mapped through the p03 tree's Makefiles),
* the tree must be the same major version the patchset was rebased on
  (currently `7.2.6` — override with `--version` when the patchset moves).

**Important:** kconfig's `conf` rewrites `.config` and strips arbitrary
comments on every `olddefconfig`/`merge_config.sh` pass. The `# TODO:`
markers are injected as the *last* step, so they survive — but they will be
lost if the config is later run through kconfig again. Re-run the generator
rather than hand-editing.

## Design notes

* `streamline_config.pl` (i.e. `make localmodconfig`) can only turn `=m`
  **off**; it cannot resurrect a symbol the base config leaves off. The
  active set is therefore derived from the running kernel's full config
  through the p03 tree's Makefiles, then force-enabled.
* `olddefconfig` silently drops symbols whose Kconfig parents are invisible
  (`depends on`, enclosing `if`, even across `source` chains such as
  `drivers/media/cec/platform/Kconfig` inheriting
  `if MEDIA_CEC_SUPPORT`), so the generator rebuilds the dependency
  closure: for every unresolved whitelist symbol it re-asserts the symbol
  (when promptful), enables its depends/if gates with the running kernel's
  values as the oracle, and resolves promptless symbols
  (`tristate`/`bool` without a prompt — e.g. `CEC_CORE`, `NVME_AUTH`) by
  enabling exactly one `select`ing parent, chosen by lowest-cost priority,
  plus that select's `if` condition as a guard.
* Kconfig's `conf` strips arbitrary `#` comments whenever it rewrites
  `.config`, which is why the `# TODO:` markers are injected as the final
  step after all kconfig passes complete.