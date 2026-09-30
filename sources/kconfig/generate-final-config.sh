#!/usr/bin/env bash
# ==============================================================================
# generate-final-config.sh
#
# Produces sources/kconfig/final-kernel.config: the p03 7.2 kernel config for
# THIS machine, merged from minimal-kernel.config (base skeleton) and
# linux-p03.config (tuning fragment), then trimmed so that
#
#   =m  ONLY for:  + modules currently loaded on this system (lsmod snapshot)
#                   + gaming/handheld modules shipped by linux-p03.config
#                   + "future-proofing" modules listed in FUTURE_MODULES below
#                     (each one is flagged with a "# TODO:" line in the output)
#
# Everything else stays built-in (=y) or off (=n), exactly as the base configs
# say. Boot-critical storage/filesystem drivers are kept =y (the fragment's
# own "boot robustness" section), so a broken or mismatched initramfs still
# reaches the rootfs.
#
# The pipeline mirrors kernel-p03.spec's %prep config phase (same merge order,
# same scripts/config tweaks for tickrate, ISA level, secureboot, LTO and opt
# level), but replaces the spec's generic linux-tkg modprobed.db with a live
# snapshot of THIS system's loaded modules.
#
# Usage:  bash sources/kconfig/generate-final-config.sh [--workdir DIR] [--version N.N.N]
#         (run from anywhere in the repo; requires network on first run)
#
# The workdir holds the vanilla tarball, the patch-applied source tree and the
# lsmod snapshot. It is created on demand and reused on later runs.
# ==============================================================================
set -uo pipefail

# ----------------------------------------------------------------- config ---
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCONFIG_DIR="${SCRIPT_DIR}"

KVER="7.2.6"                          # vanilla base the patchset is rebased on
WORKDIR="${TMPDIR:-/tmp}/opencode-p03-config"
OUTPUT="${KCONFIG_DIR}/final-kernel.config"

BASE_CONFIG="${KCONFIG_DIR}/minimal-kernel.config"
FRAGMENT="${KCONFIG_DIR}/linux-p03.config"
PATCH_DIRS=("${REPO_ROOT}/sources/patchset" "${REPO_ROOT}/sources/patches-p03")

MIRROR="https://cdn.kernel.org/pub/linux/kernel/v7.x"

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir) WORKDIR="$2"; shift 2 ;;
        --version) KVER="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

TREE="${WORKDIR}/linux-${KVER}"
LSMOD="${WORKDIR}/lsmod.snapshot"
ACTIVE="${WORKDIR}/active-symbols.txt"

# --- gaming/handheld modules shipped by linux-p03.config, kept as =m --------
# (these are the p03 "gaming stuff": handheld consoles, controllers, RGB,
#  console audio, and the fragment's own "handheld docks / Deck-class" USB
#  controllers. None of them load on this desktop today, but the user wants
#  them present so the kernel stays "gaming ready".)
GAMING_MODULES=(
    HID_LENOVO_GO        HID_LENOVO_GO_S      HID_MSI          ZOTAC_ZONE_HID
    ZOTAC_ZONE_PLATFORM  LEDS_VALVE           SND_SOC_AW87XXX  MFD_STEAMDECK
    EXTCON_STEAMDECK     SENSORS_STEAMDECK    LEDS_STEAMDECK   HID_ASUS_ALLY
    HID_REDRAGON         AYN_EC               LENOVO_WMI_CAPDATA JOYSTICK_AS5011
    JOYSTICK_FSIA6B      JOYSTICK_SENSEHAT    JOYSTICK_SEESAW  USB_CHIPIDEA
    USB_CHIPIDEA_PCI     USB_CHIPIDEA_MSM     USB_CHIPIDEA_NPCM USB_CHIPIDEA_GENERIC
    USB_ISP1760
)

# --- future-proofing modules: =m + "# TODO:" comment in the output ---------
# Reasonable "just in case" additions for THIS system (desktop, USB storage,
# external drives, VPN, controllers). Each entry: CONFIG_SYMBOL|short reason.
FUTURE_MODULES=(
    "EXFAT_FS|USB sticks / SD cards formatted exFAT"
    "NTFS3_FS|external NTFS-formatted drives (replaces the fragment's legacy NTFS_FS)"
    "SQUASHFS|AppImage/snap/Steam container images"
    "ISO9660_FS|mounting ISO images"
    "CIFS|SMB/CIFS network shares (NAS)"
    "WIREGUARD|wireguard VPN tunnel"
    "JOYSTICK_XPAD|Xbox controllers (gaming)"
    "HID_NINTENDO|Switch-style controllers (gaming)"
    "HID_SONY|PlayStation/DualShock controllers (gaming)"
    "USB_SERIAL_CP210X|USB-UART adapters (embedded dev)"
    "USB_SERIAL_CH341|cheap USB-UART adapters"
    "USB_SERIAL_FTDI_SIO|FTDI USB-UART adapters"
)

# =============================================================================
# Step 0: prepare the patched p03 tree (fetch vanilla + apply patchset)
# =============================================================================
prepare_tree() {
    [ -d "${TREE}" ] && return 0
    mkdir -p "${WORKDIR}"
    local tb="${WORKDIR}/linux-${KVER}.tar.xz"
    if [ ! -f "${tb}" ]; then
        echo "== fetching vanilla linux-${KVER} =="
        curl -sSL -o "${tb}" "${MIRROR}/linux-${KVER}.tar.xz" || { echo "download failed" >&2; exit 1; }
    fi
    echo "== extracting =="
    tar xf "${tb}" -C "${WORKDIR}"

    mkdir -p "${WORKDIR}/patches"
    for d in "${PATCH_DIRS[@]}"; do
        [ -d "$d" ] && cp "${d}"/*.patch "${WORKDIR}/patches/" 2>/dev/null
    done

    echo "== applying $(ls "${WORKDIR}"/patches/*.patch | wc -l) p03 patches (sorted, fuzz=2) =="
    cd "${TREE}"
    local fails=0
    for p in $(ls "${WORKDIR}"/patches/*.patch | sort); do
        if ! patch -p1 --fuzz=2 --batch --silent < "$p" 2>/dev/null; then
            echo "FAILED: $(basename "$p")" >&2
            fails=$((fails+1))
        fi
    done
    find . -name '*.orig' -delete
    find . -name '*.rej' -delete
    [ "$fails" -eq 0 ] || { echo "patch application failed ($fails)" >&2; exit 1; }
    echo "== tree ready: ${TREE} =="
}

# =============================================================================
# Step 1: ACTIVE set — CONFIG symbols of modules loaded on THIS system
# =============================================================================
# streamline_config.pl (make localmodconfig) is a one-way street: it can only
# turn OFF =m lines, never resurrect a =n symbol. So we derive the active
# symbol list from the RUNNING kernel's full config through the p03 tree's own
# Makefiles, then force-enable those symbols afterwards.
compute_active() {
    lsmod > "${LSMOD}"
    cp "${LSMOD}" "${KCONFIG_DIR}/lsmod.snapshot"   # reproducible alongside the output
    echo "== lsmod snapshot: $(($(wc -l < "${LSMOD}")-1)) modules loaded =="
    local running_config
    running_config="/lib/modules/$(uname -r)/build/.config"
    if [ ! -f "${running_config}" ]; then
        echo "ERROR: no running-kernel config at ${running_config}" >&2
        echo "       (kernel-devel package not installed; cannot map module names to CONFIG_*)" >&2
        exit 1
    fi

    cd "${TREE}"
    cp "${running_config}" .config
    LSMOD="${LSMOD}" make localmodconfig >/dev/null 2>&1 || true
    grep '=m$' .config | sed 's/=m$//' > "${ACTIVE}"

    # Not-loaded exclusions: modules the running distro kernel ships as =m
    # but that streamline_config.pl keeps anyway (def_tristate defaults or
    # dependency chains of the AMD SOF family) and that this machine —
    # Intel-only desktop — can never load. They fail the "only modules that
    # are active currently" rule, so drop them from the whitelist.
    local excl
    for excl in SND_SOC_SOF_AMD_TOPLEVEL SND_SOC_SOF_AMD_COMMON \
                 SND_SOC_SOF_AMD_RENOIR SND_SOC_SOF_ACP_PROBES \
                 SND_SOC_ACPI_AMD_MATCH SOUNDWIRE_AMD; do
        grep -vxF "CONFIG_${excl}" "${ACTIVE}" > "${ACTIVE}.tmp" && mv "${ACTIVE}.tmp" "${ACTIVE}"
    done
    echo "== active module symbols: $(wc -l < "${ACTIVE}") =="
}

# =============================================================================
# Step 2: base + fragment + spec tweaks, then whitelist enforcement
# =============================================================================
build_config() {
    cd "${TREE}"

    # 2.1 canonicalize the minimal base against the patched tree
    #     (drops stale 6.19-era symbols like SCHED_BORE, resolves p03 symbols)
    cp "${BASE_CONFIG}" .config
    make olddefconfig >/dev/null 2>&1

    # 2.2 merge the p03 tuning fragment (mirrors kernel-p03.spec %prep)
    ./scripts/kconfig/merge_config.sh -m .config "${FRAGMENT}" >/dev/null 2>&1

    # 2.3 spec's post-merge Kconfig tweaks (spec defaults: tick 750, ISA v3,
    #     secureboot block, ThinLTO+Polly clang, O2)
    ./scripts/config --enable GENERIC_CPU
    ./scripts/config --enable HZ_750 --enable HZ_750_NODEF --set-val HZ 750
    ./scripts/config --set-val X86_64_VERSION 3
    ./scripts/config -e IMA -e IMA_APPRAISE -e IMA_APPRAISE_BOOTPARAM -e IMA_APPRAISE_MODSIG \
        -e IMA_ARCH_POLICY -e IMA_SECURE_AND_OR_TRUSTED_BOOT
    ./scripts/config -d IMA_DEFAULT_HASH_SHA1 -e IMA_DEFAULT_HASH_SHA256 --set-str IMA_DEFAULT_HASH "sha256"
    ./scripts/config -e MODULE_SIG -e MODULE_SIG_ALL -d MODULE_SIG_FORCE \
        -e MODULE_SIG_SHA512 --set-str MODULE_SIG_HASH sha512
    ./scripts/config -e KEXEC_SIG -e INTEGRITY_ASYMMETRIC_KEYS -e INTEGRITY_SIGNATURE
    ./scripts/config -e LOCK_DOWN_KERNEL_FORCE_NONE -e SECURITY_LOCKDOWN_LSM -e SECURITY_LOCKDOWN_LSM_EARLY
    ./scripts/config -e SYSTEM_EXTRA_CERTIFICATE --set-val SYSTEM_EXTRA_CERTIFICATE_SIZE 4096
    ./scripts/config -e SYSTEM_TRUSTED_KEYRING
    ./scripts/config -d CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT
    ./scripts/config -d LTO_NONE -e POLLY_CLANG -e LTO_CLANG_THIN -d LTO_CLANG_FULL
    ./scripts/config -e CC_OPTIMIZE_FOR_PERFORMANCE -d CC_OPTIMIZE_FOR_PERFORMANCE_O3 -d CC_OPTIMIZE_FOR_SIZE

    # 2.4 whitelist: force-enable active + gaming + future as modules
    local sym
    while read -r sym; do
        ./scripts/config --module "$sym" 2>/dev/null || true
    done < "${ACTIVE}"
    for sym in "${GAMING_MODULES[@]}"; do
        ./scripts/config --module "$sym" 2>/dev/null || true
    done
    for entry in "${FUTURE_MODULES[@]}"; do
        ./scripts/config --module "${entry%%|*}" 2>/dev/null || true
    done

    # 2.4b boot-critical =y enforcement: the fragment pulls the storage and
    # filesystem drivers needed to reach a rootfs built in ("link in what is
    # needed to reach a rootfs so a broken or mismatched initramfs still
    # boots"). The whitelist pass above uses the running system's values,
    # which ship these as loadable modules — that would *downgrade* them to
    # =m, so re-assert the fragment's own =y choices here.
    local boot_y sym
    for sym in NVME_CORE BLK_DEV_NVME USB_STORAGE MSDOS_FS VFAT_FS FAT_FS SATA_AHCI BTRFS_FS; do
        ./scripts/config -e "$sym" 2>/dev/null || true
        printf '%-16s' "$sym"; grep -E "^CONFIG_${sym}=" .config
    done
    # (IGC / DRM_I915 / I2C_I801 stay whatever minimal + fragment say: not
    #  part of the rootfs-critical path, and =m there is fine.)

    # 2.5 prune: every remaining =m that is not in the whitelist goes to =n
    local keep m sym entry
    while read -r sym; do
        keep=0
        grep -qxF "$sym" "${ACTIVE}" && keep=1
        for m in "${GAMING_MODULES[@]}"; do
            [ "$sym" = "CONFIG_${m}" ] && keep=1
        done
        for entry in "${FUTURE_MODULES[@]}"; do
            [ "$sym" = "CONFIG_${entry%%|*}" ] && keep=1
        done
        if [ "$keep" -eq 0 ]; then
            ./scripts/config -d "$sym"
        fi
    done < <(grep '=m$' .config | sed 's/=m$//' | sort -u)

    # 2.6 resolve + transitive dependency repair loop
    #
    # olddefconfig drops symbols whose parents are invisible. The minimal
    # skeleton leaves whole menus off (MD, VIRTUALIZATION, SPI, MTD,
    # WATCHDOG, EXTCON, SND_SOC_SOF_TOPLEVEL, ...), and Kconfig "if EXPR"
    # nesting is just as binding as "depends on". The running kernel's
    # config is our oracle: when a target symbol does not resolve, parse its
    # "depends on"/"default ... if" lines AND the enclosing "if" stack from
    # its Kconfig file, enable those parents with the oracle's values, and
    # keep repairing transitively until every target is y/m (bounded).
    #
    # Two Kconfig rules make this non-trivial:
    #  * "select" is the only way to give a PROMPTLESS symbol (e.g. BT_MTK,
    #    NVME_AUTH, 842_COMPRESS) a value — conf cannot set it from .config.
    #    Those targets are repaired by enabling their *selectors* instead.
    #  * only enable a parent/selector when the oracle ships it as =y or =m;
    #    pulling in symbols the running kernel does not enable would carry
    #    whole unrelated subsystems into the build.
    local oracle="/lib/modules/$(uname -r)/build/.config"
    local max_iter=48 iter=0 sym parent kf
    local targets="${WORKDIR}/repair-targets"

    # ------------------------------------------------------------------
    # Build a one-time full-tree Kconfig index so the repair loop never
    # greps the whole tree per symbol (that per-symbol walk was what hung
    # the earlier runs):
    #   kconfig-index.tsv : SYM \t def-file \t has_prompt \t depends-tokens
    #   source-map.tsv    : sourced-file \t owner-file \t if-gate
    #   select-map.tsv    : selector \t selected \t select-if-condition
    # A promptless symbol (tristate/bool without a quoted prompt) can only
    # get a value via "select", so repair works on its selectors instead.
    # ------------------------------------------------------------------
    local idx="${WORKDIR}/kconfig-index.tsv"
    local smap="${WORKDIR}/source-map.tsv"
    local selmap="${WORKDIR}/select-map.tsv"
    local defmap="${WORKDIR}/def-file-map.tsv"

    build_index() {
        echo "== building Kconfig index (one-time pass) =="
        find . -name 'Kconfig*' -type f 2>/dev/null | sort > "${WORKDIR}/kconfig-files"
        : > "${idx}.tmp"; : > "${smap}.tmp"; : > "${selmap}.tmp"

        while IFS= read -r kf; do
            # 1) symbol index: def file, prompt flag, if-gates + depends tokens
            awk -v file="$kf" '
                function flush() { if (cur != "") printf "%s\t%s\t%d\t%s\n", cur, file, prompt, deps }
                /^[[:space:]]*if[[:space:]]+/ {
                    c = $0; sub(/^[[:space:]]*if[[:space:]]*/, "", c)
                    sub(/^[[:space:](*]+/, "", c); sub(/[)][[:space:]]*$/, "", c)
                    stack[++top] = c; next
                }
                /^endif([[:space:]]|$)/ { if (top) top--; next }
                /^(config|menuconfig)[[:space:]]+/ {
                    flush(); cur = $2; prompt = 0
                    deps = ""
                    for (i = 1; i <= top; i++) deps = deps " " stack[i]
                    next
                }
                /^[[:space:]]*(tristate|bool)[[:space:]]+"/ { prompt = 1; next }
                /^[[:space:]]*depends[[:space:]]+on[[:space:]]+/ {
                    d = $0; sub(/^[[:space:]]*depends[[:space:]]+on[[:space:]]*/, "", d); deps = deps " " d; next
                }
                END { flush() }
            ' "$kf" >> "${idx}.tmp"

            # 2) source edges: sourced file \t owner \t enclosing if-stack
            awk -v owner="$kf" '
                /^[[:space:]]*if[[:space:]]+/ {
                    c = $0; sub(/^[[:space:]]*if[[:space:]]*/, "", c)
                    sub(/^[[:space:](*]+/, "", c); sub(/[)][[:space:]]*$/, "", c)
                    stack[++top] = c; next
                }
                /^endif([[:space:]]|$)/ { if (top) top--; next }
                /^[[:space:]]*source[[:space:]]+/ {
                    t = $0; sub(/^[[:space:]]*source[[:space:]]+/, "", t)
                    gsub(/"/, "", t)
                    if (top == 0) print t "\t" owner "\t-"
                    else for (i = 1; i <= top; i++) print t "\t" owner "\t" stack[i]
                    next
                }
            ' "$kf" >> "${smap}.tmp"

            # 3) select edges: selector \t selected \t condition
            awk '
                /^(config|menuconfig)[[:space:]]+/ { cur = $2; next }
                /^[[:space:]]*select[[:space:]]+[A-Z0-9_]/ {
                    t = $2; cond = "-"
                    if (match($0, /[[:space:]]if[[:space:]]+(.*)$/, c)) cond = c[1]
                    print cur "\t" t "\t" cond
                }
            ' "$kf" >> "${selmap}.tmp"
        done < "${WORKDIR}/kconfig-files"

        sort -u -o "${idx}.tmp" "${idx}.tmp"; mv "${idx}.tmp" "${idx}"
        sort -u -o "${smap}.tmp" "${smap}.tmp"; mv "${smap}.tmp" "${smap}"
        sort -u -o "${selmap}.tmp" "${selmap}.tmp"; mv "${selmap}.tmp" "${selmap}"
        awk -F'\t' '!($1 in seen) { seen[$1] = 1; print $1 "\t" $2 }' "${idx}" > "${defmap}"
        echo "  indexed $(wc -l < "${idx}") symbol defs, $(wc -l < "${smap}") source edges, $(wc -l < "${selmap}") select edges"
    }

    # guard symbols of $1 (no CONFIG_ prefix): depends tokens + the if-gates
    # inherited from every Kconfig that sources its definition file
    deps_of() {
        local df dfn
        df=$(awk -F'\t' -v s="$1" '$1 == s { print $2; exit }' "${defmap}")
        dfn="${df#./}"   # source directives use srctree-relative paths
        {
            awk -F'\t' -v s="$1" -v f="$df" '$1 == s && $2 == f { print $4 }' "${idx}"
            if [ -n "$dfn" ]; then
                awk -F'\t' -v f="$dfn" '$1 == f && $3 != "-" { print $3 }' "${smap}"
            fi
        } | grep -oE '\b[A-Z][A-Z0-9_]{1,}\b' \
          | grep -vE '^(CONFIG|AND|OR|NOT|IF|HELP|DEFAULT|DEPENDS|SELECT|ON|Y|M|N|COMPILE_TEST)$' \
          | sort -u
    }
    prompt_of() {
        awk -F'\t' -v s="$1" '$1 == s { print $3; exit }' "${idx}"
    }
    selectors_of() {
        awk -F'\t' -v s="$1" '$2 == s { print $1 "\t" $3 }' "${selmap}" | sort -u
    }

    # seed targets: every whitelisted symbol
    build_index
    cat "${ACTIVE}" > "${targets}"
    cat "${ACTIVE}" > "${WORKDIR}/wl-orig.txt"   # static: original whitelist
    for m in "${GAMING_MODULES[@]}" "${FUTURE_MODULES[@]%%|*}"; do
        echo "CONFIG_${m}" >> "${targets}"
        echo "CONFIG_${m}" >> "${WORKDIR}/wl-orig.txt"
    done
    sort -u -o "${targets}" "${targets}"
    sort -u -o "${WORKDIR}/wl-orig.txt" "${WORKDIR}/wl-orig.txt"

    while :; do
        make olddefconfig >/dev/null 2>&1

        # targets that are not y/m yet
        syms=()
        while read -r sym; do
            grep -qE "^${sym}=m$|^${sym}=y$" .config || syms+=("$sym")
        done < "${targets}"
        [ "${#syms[@]}" -eq 0 ] && break
        iter=$((iter+1))
        [ "$iter" -gt "$max_iter" ] && break

        # re-assert PROMPTFUL missing targets (olddefconfig deletes invisible
        # symbols from .config), then gather parents + selectors to enable.
        : > "${WORKDIR}/repair-list"
        for sym in "${syms[@]}"; do
            tmp_sym="${sym#CONFIG_}"
            prompted=$(prompt_of "${tmp_sym}")
            if [ "${prompted:-0}" = "1" ]; then
                # promptful: re-assert itself (module if oracle =m, else y)
                if grep -qE "^${sym}=m$" "${oracle}" 2>/dev/null; then
                    ./scripts/config --module "$sym" 2>/dev/null || true
                else
                    ./scripts/config -e "$sym" 2>/dev/null || true
                fi
            fi
            # promptless: only ONE selector can give it a value — pick it by
            # minimal-cost priority and guard ONLY that selection:
            #   1. selector already =y/=m in .config (select fires for free)
            #   2. selector itself whitelisted (active/gaming/future)
            #   3. selector oracle=y  (bool — cheapest)
            #   4. selector oracle=m  (another real module)
            # "default m" symbols (TDX_HOST_SERVICES, NFT_COMPAT_ARP) need no
            # selector at all: they resolve once their guards are set.
            if [ "${prompted:-0}" != "1" ]; then
                sels=$(selectors_of "${tmp_sym}")   # "SEL<TAB>COND-or-dash" lines
                # candidates in priority order; each candidate keeps its own
                # select-if condition so it can be guarded correctly.
                found=""
                if [ -n "$sels" ]; then
                    # (1) already y/m in .config  (2) whitelisted
                    while IFS=$'\t' read -r s c; do
                        [ -z "$s" ] && continue
                        if grep -qE "^CONFIG_${s}=m$|^CONFIG_${s}=y$" .config \
                           || grep -qxF "CONFIG_${s}" "${WORKDIR}/wl-orig.txt"; then
                            found="$s"$'\t'"$c"; break
                        fi
                    done <<EOF2
$(echo "$sels")
EOF2
                    # (3) oracle=y bool, (4) oracle=m
                    if [ -z "$found" ]; then
                        while IFS=$'\t' read -r s c; do
                            [ -z "$s" ] && continue
                            mode=""
                            grep -qE "^CONFIG_${s}=y$" "${oracle}" && mode=y
                            grep -qE "^CONFIG_${s}=m$" "${oracle}" && mode=m
                            if [ "$mode" = "y" ] || { [ "$mode" = "m" ] && [ -z "$found" ]; }; then
                                found="$s"$'\t'"$c"; break
                            fi
                        done <<EOF2
$(echo "$sels")
EOF2
                    fi
                fi
                if [ -n "$found" ]; then
                    pick="${found%%$'\t'*}"
                    cond="${found#*$'\t'}"
                    [ "$cond" = "$pick" ] || [ "$cond" = "-" ] && cond=""
                    echo "CONFIG_${pick}" >> "${WORKDIR}/repair-list"
                    if [ -n "$cond" ]; then
                        echo "$cond" | grep -oE '\b[A-Z][A-Z0-9_]{1,}\b' \
                            | grep -vE '^(CONFIG|AND|OR|NOT|IF|HELP|DEFAULT|DEPENDS|SELECT|ON|Y|M|N|COMPILE_TEST)$' \
                            | sed 's/^/CONFIG_/' >> "${WORKDIR}/repair-list"
                    fi
                fi
            fi
            deps_of "${tmp_sym}" | sed 's/^/CONFIG_/' >> "${WORKDIR}/repair-list"
        done

        # enable parents/selectors — ONLY those the oracle ships as =y or =m
        # — and add them to the transitive target set
        while read -r parent; do
            [ -z "$parent" ] && continue
            grep -qE "^${parent}=y$|^${parent}=m$" .config && continue
            if grep -qE "^${parent}=m$" "${oracle}" 2>/dev/null; then
                ./scripts/config --module "$parent" 2>/dev/null || true
                echo "$parent" >> "${targets}"
            elif grep -qE "^${parent}=y$" "${oracle}" 2>/dev/null; then
                ./scripts/config -e "$parent" 2>/dev/null || true
                echo "$parent" >> "${targets}"
            fi
        done < <(sort -u "${WORKDIR}/repair-list")
        sort -u -o "${targets}" "${targets}"
        echo "  repair iteration ${iter}: ${#syms[@]} unresolved, targets now $(wc -l < "${targets}")"
    done

    # 2.7 SOF platform trim: this machine loads only the CNL and TGL-family
    #     SOF PCI drivers (i9-13900K: `snd_sof_pci_intel_{cnl,tgl}`). The SOF
    #     toplevel gates the other platform wrappers with def_tristate m
    #     defaults, so once the stack is needed, SoC/arch families for
    #     hardware this desktop does not have would be enabled too — turn
    #     those off explicitly and resolve once more.
    ./scripts/config -d SND_SOC_SOF_AMD_TOPLEVEL -d SND_SOC_SOF_MTK_COMMON \
        -d SND_SOC_SOF_IMX_COMMON -d SND_SOC_SOF_INTEL_SKL \
        -d SND_SOC_SOF_INTEL_APL -d SND_SOC_SOF_INTEL_ICL \
        -d SND_SOC_SOF_INTEL_MTL -d SND_SOC_SOF_INTEL_LNL \
        -d SND_SOC_SOF_INTEL_NVL -d SND_SOC_SOF_INTEL_PTL \
        -d SND_SOC_SOF_MERRIFIELD -d SND_SOC_SOF_LUNARLAKE -d SND_SOC_SOF_NOVALAKE
    make olddefconfig >/dev/null 2>&1
}

# =============================================================================
# Step 3: verify the whitelist survived (dependencies may have dropped some)
# =============================================================================
verify() {
    local missing=0 sym m entry
    echo "== verification =="
    for sym in NVME_CORE BLK_DEV_NVME USB_STORAGE VFAT_FS FAT_FS BTRFS_FS; do
        grep -qE "^CONFIG_${sym}=y$" .config || { echo "  BOOT-CRITICAL NOT =y: CONFIG_${sym}" >&2; missing=1; }
    done
    while read -r sym; do
        if ! grep -qE "^${sym}=" .config; then
            echo "  MISSING (did not resolve): ${sym}" >&2
            missing=1
        elif grep -qE "^${sym}=n$|^# ${sym} is not set" .config; then
            echo "  DROPPED (deps unmet or not visible): ${sym}" >&2
            missing=1
        fi
    done < "${ACTIVE}"
    for m in "${GAMING_MODULES[@]}"; do
        grep -qE "^CONFIG_${m}=m$" .config || { echo "  GAMING NOT =m: CONFIG_${m}" >&2; missing=1; }
    done
    for entry in "${FUTURE_MODULES[@]}"; do
        sym="${entry%%|*}"
        grep -qE "^CONFIG_${sym}=m$" .config || { echo "  FUTURE NOT =m: CONFIG_${sym}" >&2; missing=1; }
    done
    [ "$missing" -eq 0 ] || { echo "VERIFY FAILED — fix dependencies and rerun" >&2; exit 1; }
    echo "== all ${ACTIVE##*/} + gaming + future symbols are =m =="
}

# =============================================================================
# Step 4: emit the final config with TODO markers for future modules
# =============================================================================
emit() {
    local tmp header
    tmp="${WORKDIR}/final-kernel.config"
    cp .config "${tmp}"

    # header explaining the module policy (inserted after the first two lines)
    read -r -d '' header <<'EOF' || true
#
# =====================================================================
# final-kernel.config - p03 7.2 kernel, optimized for this machine
# =====================================================================
# Generated by sources/kconfig/generate-final-config.sh — do not hand-edit.
#
# Module policy:
#   =m  only for modules loaded at generation time (see lsmod.snapshot),
#       plus the gaming/handheld modules from linux-p03.config,
#       plus the future-proofing modules marked "# TODO:" below.
#   =y  boot-critical and p03 feature options (scheduler, pstore, ...).
#   =n  everything else (fragment's generic module bloat is pruned).
EOF
    awk -v header="$header" 'NR == 2 { print; print header; next } { print }' \
        "${tmp}" > "${tmp}.new" && mv "${tmp}.new" "${tmp}"

    # inject "# TODO:" lines above each future module
    local sym reason
    for entry in "${FUTURE_MODULES[@]}"; do
        sym="${entry%%|*}"
        reason="${entry#*|}"
        awk -v sym="$sym" -v reason="$reason" '
            $0 ~ "^CONFIG_" sym "=m$" { print "# TODO: " sym " -- " reason " (future-proofing, not loaded today)"; }
            { print }
        ' "${tmp}" > "${tmp}.new" && mv "${tmp}.new" "${tmp}"
    done

    cp "${tmp}" "${OUTPUT}"
    echo "== written: ${OUTPUT} =="
}

prepare_tree
compute_active
build_config
verify
emit

echo
echo "final =m count: $(grep -c '=m$' "${OUTPUT}")"
echo "final =y count: $(grep -c '=y$' "${OUTPUT}")"
echo "TODO comments:  $(grep -c '# TODO:' "${OUTPUT}")"