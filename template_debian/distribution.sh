#!/bin/bash -e
# vim: set ts=4 sw=4 sts=4 et :

source ./functions.sh >/dev/null
source ./umount_kill.sh >/dev/null

output "${bold}${under}INFO: ${SCRIPTSDIR}/distribution.sh imported by: ${0}${reset}"

# ==============================================================================
# Cleanup function
# ==============================================================================
function cleanup() {
    errval=$?
    trap - ERR EXIT
    trap
    error "${1:-"${0}: Error.  Cleaning up and un-mounting any existing mounts"}"
    umount_all || true

    exit $errval
}

# ==============================================================================
# If .prepared_debootstrap has not been completed, don't continue
# ==============================================================================
function exitOnNoFile() {
    file="${1}"
    message="${2}"

    if ! [ -f "${file}" ]; then
        error "${message}"
        umount_all || true
        exit 1
    fi
}

# ==============================================================================
# Umount everthing within INSTALLDIR or $1 but kill all processes within first
# ==============================================================================
function umount_all() {
    directory="${1:-"${INSTALLDIR}"}"

    # Only remove dirvert policies, etc if base INSTALLDIR mount is being umounted
    if [ "${directory}" == "${INSTALLDIR}" -o "${directory}" == "${INSTALLDIR}/" ]; then
        if [ -n "$(mountPoints)" ]; then
            removeDbusUuid
            removeDivertPolicy
        fi
    fi

    umount_kill "${directory}" || true
}

# ==============================================================================
# Create snapshot
# ==============================================================================
function createSnapshot() {
    snapshot_name="${1}"

    if [ "${SNAPSHOT}" == "1" ]; then
        splitPath "${IMG}" path_parts
        snapshot_path="${path_parts[dir]}${path_parts[base]}-${snapshot_name}${path_parts[dotext]}"

        # create snapshot
        info "Creating snapshot of ${IMG} to ${snapshot_path}"
        sync
        cp -f "${IMG}" "${snapshot_path}"
    fi
}

# ==============================================================================
# Create DBUS uuid
# ==============================================================================
function createDbusUuid() {
    outputc green "Creating DBUS uuid..."
    removeDbusUuid
    if [ -e "${INSTALLDIR}/bin/dbus-uuidgen" ]; then
        chroot_cmd dbus-uuidgen --ensure 1>/dev/null 2>&1
    fi
}

# ==============================================================================
# Remove DBUS uuid
# ==============================================================================
function removeDbusUuid() {
    if [ -e "${INSTALLDIR}"/var/lib/dbus/machine-id ]; then
        outputc red "Removing generated machine uuid..."
        rm "${INSTALLDIR}/var/lib/dbus/machine-id"
    fi
}

# ==============================================================================
# Set up a temporary dpkg-divert policy to prevent apt from starting services
# on package installation
# ==============================================================================
function addDivertPolicy() {
    outputc green "Deactivating initctl..."
    chroot_cmd dpkg-divert --local --rename --add /sbin/initctl || true

    outputc green "Creating policy-rc.d"
    echo exit 101 > "${INSTALLDIR}/usr/sbin/policy-rc.d"
    chmod +x "${INSTALLDIR}/usr/sbin/policy-rc.d"

    # utopic systemd install still broken...
    outputc green "Hacking invoke-rc.d to ignore missing init scripts..."
    chroot_cmd sed -i -e "s/exit 100/exit 0 #exit 100/" /usr/sbin/invoke-rc.d
}

# ==============================================================================
# Remove temporary dpkg-divert policy
# ==============================================================================
function removeDivertPolicy() {
    outputc red "Reactivating initctl..."
    chroot_cmd dpkg-divert --local --rename --remove /sbin/initctl || true

    outputc green "Removing policy-rc.d"
    rm -f "${INSTALLDIR}/usr/sbin/policy-rc.d"

    outputc red "Restoring invoke-rc.d..."
    chroot_cmd sed -i -e "s/exit 0 #exit 100/exit 100/" /usr/sbin/invoke-rc.d
}

# ==============================================================================
# Create system mount points
# ==============================================================================
function prepareChroot() {
    # Make sure nothing is mounted within $INSTALLDIR
    umount_kill "${INSTALLDIR}/"

    mount -t tmpfs none "${INSTALLDIR}/run"
    if [ "${SYSTEMD_NSPAWN_ENABLE}"  != "1" ]; then
        mount -t proc proc "${INSTALLDIR}/proc"
        mount -t sysfs sys "${INSTALLDIR}/sys"
    fi
    createDbusUuid
    addDivertPolicy
}

# ==============================================================================
# apt-get upgrade
# ==============================================================================
function aptUpgrade() {
    aptUpdate
    DEBIAN_FRONTEND="noninteractive" DEBIAN_PRIORITY="critical" DEBCONF_NOWARNINGS="yes" \
        chroot_cmd env APT_LISTCHANGES_FRONTEND=none $eatmydata_maybe \
            apt-get ${APT_GET_OPTIONS} upgrade -u -y
}

# ==============================================================================
# apt-get dist-upgrade
# ==============================================================================
function aptDistUpgrade() {
    aptUpdate
    DEBIAN_FRONTEND="noninteractive" DEBIAN_PRIORITY="critical" DEBCONF_NOWARNINGS="yes" \
        chroot_cmd env APT_LISTCHANGES_FRONTEND=none $eatmydata_maybe \
            apt-get ${APT_GET_OPTIONS} dist-upgrade -u -y
}

# ==============================================================================
# apt-get update
# ==============================================================================
function aptUpdate() {
    debug "Updating system"
    DEBIAN_FRONTEND="noninteractive" DEBIAN_PRIORITY="critical" DEBCONF_NOWARNINGS="yes" \
        chroot_cmd apt-get ${APT_GET_OPTIONS} update
}

# ==============================================================================
# apt-get remove
# ==============================================================================
function aptRemove() {
    files="$@"
    DEBIAN_FRONTEND="noninteractive" DEBIAN_PRIORITY="critical" DEBCONF_NOWARNINGS="yes" \
        chroot_cmd $eatmydata_maybe apt-get ${APT_GET_OPTIONS} --force-yes remove ${files[@]}
}

# ==============================================================================
# apt-get install
# ==============================================================================
function aptInstall() {
    files="$@"
    DEBIAN_FRONTEND="noninteractive" DEBIAN_PRIORITY="critical" DEBCONF_NOWARNINGS="yes" \
        chroot_cmd $eatmydata_maybe apt-get ${APT_GET_OPTIONS} install ${files[@]}
    retcode=$?
    chroot_cmd apt-get ${APT_GET_OPTIONS} clean
    return $retcode
}

# ==============================================================================
# Install extra packages in script_${DIST}/packages.list file
# -and / or- TEMPLATE_FLAVOR directories
# ==============================================================================
function installPackages() {

    # Install custom (specified) packages -or- a list of package names
    if [ -n "${1}" ]; then
        # Example: installPackages packages_qubes.list
        if [ ${#@} == "1" ]; then
            getFileLocations packages_list "${1}" ""

        # Example: installPackages somefile1.list somefile2.list
        else
            packages_list="$@"
        fi

    # Install distribution related packages
    # Example: installPackages
    else
        getFileLocations packages_list "packages.list" "${DIST}"
        if [ -z "${packages_list}" ]; then
            error "Can not locate a package.list file!"
            umount_all || true
            exit 1
        fi
    fi

    for package_list in ${packages_list[@]}; do
        debug "Installing extra packages from: ${package_list}"
        declare -a packages
        readarray -t packages < "${package_list}"

        info "Packages: "${packages[@]}""
        aptInstall "${packages[@]}"
    done
}

# ==============================================================================
# Install Systemd
# ==============================================================================
function installSystemd() {
    buildStep "$0" "pre-systemd"
    chroot_cmd apt-get ${APT_GET_OPTIONS} update

    aptInstall systemd
    createDbusUuid

    # Set multi-user.target as default target
    chroot_cmd rm -f /etc/systemd/system/default.target
    chroot_cmd ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

    # XXX: TEMP lets see how stuff work with upstart in control for now
    # Boot using systemd
    chroot_cmd rm -f /sbin/init
    chroot_cmd ln -sf /lib/systemd/systemd /sbin/init

    buildStep "$0" "post-systemd"
}

# ==============================================================================
# ------------------------------------------------------------------------------
#                 C O N F I G U R A T I O N   R E L A T E D
# ------------------------------------------------------------------------------
# ==============================================================================

# ==============================================================================
# Update Debian sources.list
# ==============================================================================
function updateDebianSourceList() {
    local list="${INSTALLDIR}/etc/apt/sources.list"
    local mirror="$(cat ${INSTALLDIR}/${TMPDIR}/.mirror)"
    touch "${list}"

    # Add contrib and non-free component to repository
    sed -i "s/${DIST} main$/${DEBIANVERSION} main contrib non-free/g" "${list}"

    # Add main deb-src repository
    source="#deb-src ${mirror} main/${DEBIANVERSION} main contrib non-free"
    if ! grep -r -q "$source" "${list}"*; then
        echo -e "$source\n" >> "${list}"
    fi

    # Add Debian security repositories
    source="deb http://security.debian.org ${DEBIANVERSION}/updates main contrib non-free"
    if ! grep -r -q "$source" "${list}"*; then
        echo -e "$source" >> "${list}"
    fi
    source="#deb-src http://security.debian.org ${DEBIANVERSION}/updates main contrib non-free"
    if ! grep -r -q "$source" "${list}"*; then
        echo -e "$source\n" >> "${list}"
    fi
}

# ==============================================================================
# Add universe to sources.list
# ==============================================================================
function updateQubuntuSourceList() {
    sed -i "s/${DIST} main$/${DIST} main universe multiverse restricted/g" "${INSTALLDIR}/etc/apt/sources.list"
    source="deb http://archive.canonical.com/ubuntu ${DIST} partner"
    if ! grep -r -q "$source" "${INSTALLDIR}/etc/apt/sources.list"*; then
        touch "${INSTALLDIR}/etc/apt/sources.list"
        echo "$source" >> "${INSTALLDIR}/etc/apt/sources.list"
    fi
    source="deb-src http://archive.canonical.com/ubuntu ${DIST} partner"
    if ! grep -r -q "$source" "${INSTALLDIR}/etc/apt/sources.list"*; then
        touch "${INSTALLDIR}/etc/apt/sources.list"
        echo "$source" >> "${INSTALLDIR}/etc/apt/sources.list"
    fi
    chroot_cmd apt-get ${APT_GET_OPTIONS} update
}

# ==============================================================================
# Make sure there is a resolv.conf with network of this AppVM for building
# ==============================================================================
function createResolvConf() {
    rm -f "${INSTALLDIR}/etc/resolv.conf"
    cp /etc/resolv.conf "${INSTALLDIR}/etc/resolv.conf"
}

# ==============================================================================
# Ensure umask set in /etc/login.defs is used (022)
# ==============================================================================
function configureUmask() {
    echo "session optional pam_umask.so" >> "${INSTALLDIR}/etc/pam.d/common-session"
}

# ==============================================================================
# Configure keyboard
# ==============================================================================
function configureKeyboard() {
    debug "Setting keyboard layout"
    cat > "${INSTALLDIR}/tmp/keyboard.conf" <<'EOF'
keyboard-configuration  keyboard-configuration/variant  select  English (US)
keyboard-configuration  keyboard-configuration/layout   select  English (US)
keyboard-configuration  keyboard-configuration/model    select  Generic 105-key (Intl) PC
keyboard-configuration  keyboard-configuration/modelcode    string  pc105
keyboard-configuration  keyboard-configuration/layoutcode   string  us
keyboard-configuration  keyboard-configuration/variantcode  string
keyboard-configuration  keyboard-configuration/optionscode  string
EOF
    chroot_cmd debconf-set-selections /tmp/keyboard.conf
}

# ==============================================================================
# Update locale
# ==============================================================================
function updateLocale() {
    debug "Updating locales"
    chroot_cmd localedef -f UTF-8 -i en_US -c en_US.UTF-8
    chroot_cmd update-locale LANG=en_US.UTF-8
}


# ==============================================================================
# ------------------------------------------------------------------------------
#           Q U B E S   S P E C I F I C   F U N C T I O N S
# ------------------------------------------------------------------------------
# ==============================================================================

# ==============================================================================
# Install Qubes Repo
# ==============================================================================
installQubesRepo() {
    info " Defining Qubes CUSTOMREPO Location: ${PWD}/pkgs-for-template/${DIST}"
    export CUSTOMREPO="${PWD}/pkgs-for-template/${DIST}"

    info "Mounting local qubes_repo"
    mkdir -p "${INSTALLDIR}/tmp/qubes_repo"
    mount --bind "${CUSTOMREPO}" "${INSTALLDIR}/tmp/qubes_repo"

    cat > "${INSTALLDIR}/etc/apt/sources.list.d/qubes-builder.list" <<EOF
deb [trusted=yes] file:/tmp/qubes_repo ${DIST} main
EOF
    if [ -n "$USE_QUBES_REPO_VERSION" ]; then
        cat >> "${INSTALLDIR}/etc/apt/sources.list.d/qubes-builder.list" <<EOF
deb [arch=amd64] http://deb.qubes-os.org/r${USE_QUBES_REPO_VERSION}/vm $DIST main
EOF
       if [ "0$USE_QUBES_REPO_TESTING" -gt 0 ]; then
          cat >> "${INSTALLDIR}/etc/apt/sources.list.d/qubes-builder.list" <<EOF
deb [arch=amd64] http://deb.qubes-os.org/r${USE_QUBES_REPO_VERSION}/vm ${DIST}-testing main
EOF
        fi
        chroot_cmd apt-key add - < ${SCRIPTSDIR}/../keys/qubes-debian-r${USE_QUBES_REPO_VERSION}.asc
    fi
}

# ==============================================================================
# Uninstall Qubes Repo
# ==============================================================================
uninstallQubesRepo() {
    info ' Removing Qubes build repo from sources.list.d'

    # Lets not umount; we do that anyway when 04 exits
    umount_kill "${INSTALLDIR}/tmp/qubes_repo"
    rm -f "${INSTALLDIR}/etc/apt/sources.list.d/qubes-builder.list"
}
