# AlmaLinux 10 image-mode (bootc) base.
# Verify the tag resolves before relying on it:  podman pull quay.io/almalinuxorg/almalinux-bootc:10
FROM quay.io/almalinuxorg/almalinux-bootc:10

# --- Metadata --------------------------------------------------------------
LABEL org.opencontainers.image.title="almalinux10-bootc" \
      org.opencontainers.image.description="AlmaLinux 10 image-mode base for Garaventaville fleet" \
      org.opencontainers.image.vendor="garaventaville"

# --- Packages from Katello (governed/synced repos, not public mirrors) ------
# Register to Katello with an activation key, install everything from the synced
# repos with public mirrors disabled, then unregister so the image carries no
# consumer identity. The only public fetch is subscription-manager itself, which
# must exist before we can reach Katello (the unavoidable bootstrap). The org +
# activation key supply the repo set (BaseOS/AppStream/CRB/EPEL/Duo/Foreman
# client/...). A failed build may leave an orphaned Katello consumer to clean up.
#
# NOTE: certbot + python3-certbot-dns-cloudflare are intentionally omitted —
# EPEL upstream currently ships a broken python3-pyOpenSSL (requires
# cryptography >=46, not in EL10). Re-add them once EPEL fixes it + you re-sync.
RUN dnf -y install subscription-manager \
 && rpm -Uvh --replacepkgs http://foreman.garaventaville.com/pub/katello-ca-consumer-latest.noarch.rpm \
 && subscription-manager register --org Garaventaville --activationkey 'AlmaLinux 10' \
 && dnf -y --disablerepo='*' --enablerepo='Garaventaville_AlmaLinux_10_*' install \
        qemu-guest-agent \
        cloud-init \
        ipa-client \
        autofs \
        rsync \
        shadow-utils \
        zsh \
        perl \
        git \
        git-credential-oauth \
        vim-enhanced \
        tmux \
        bash-completion \
        yum-utils \
        htop \
        btop \
        atop \
        nmon \
        duo_unix \
        katello-host-tools \
        katello-host-tools-tracer \
 && { subscription-manager unregister || true; } \
 && { subscription-manager clean || true; } \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/lib/dnf/history.sqlite* /var/log/dnf* /var/log/hawkey.log

# katello-host-tools[-tracer] handle package-profile + enabled-repo upload to
# Katello. firewalld is absent from the base — the bootc kickstart omits the
# `firewall` directive rather than installing it.

# --- Services --------------------------------------------------------------
RUN systemctl enable qemu-guest-agent sshd

# --- Management SSH (root) keys: Foreman rex + Ascender/AWX -----------------
# %post key injection lands under /var (/root -> var/roothome, /home -> var/home)
# and does NOT survive the bootc first-boot /var init, so the management systems'
# public keys are baked into /usr instead (see image/foreman-rex.root.keys).
# Foreman rex pairs with host-group param remote_execution_ssh_user=root;
# Ascender uses its "Global Root" machine credential (user root). Both SSH in as
# root via these keys from first boot.
COPY image/foreman-rex.root.keys /usr/share/foreman-rex/root.keys
COPY image/sshd-foreman-rex.conf /etc/ssh/sshd_config.d/10-foreman-rex.conf

# --- bootc -> Katello image-mode facts -------------------------------------
# AlmaLinux's subscription-manager has no bootc fact collector; generate
# bootc.booted.image etc. on boot + every 30 min so Katello sees image mode.
COPY image/bootc-rhsm-facts /usr/libexec/bootc-rhsm-facts
COPY image/bootc-rhsm-facts.service /usr/lib/systemd/system/bootc-rhsm-facts.service
COPY image/bootc-rhsm-facts.timer /usr/lib/systemd/system/bootc-rhsm-facts.timer
RUN chmod 0644 /usr/share/foreman-rex/root.keys /etc/ssh/sshd_config.d/10-foreman-rex.conf \
 && chmod 0755 /usr/libexec/bootc-rhsm-facts \
 && systemctl enable bootc-rhsm-facts.timer

# Clean build leftovers from /tmp and /var/tmp. We deliberately do NOT touch
# /run: bootc mounts it as tmpfs at boot (build-time content is masked anyway),
# and buildah keeps live mounts there (/run/secrets, /run/.containerenv) that
# can't be removed. The cosmetic 'nonempty-run-tmp' lint warning is harmless.
RUN rm -rf /tmp/* /var/tmp/*

# bootc requires a valid, bootable image. Validate the layout at build time:
RUN bootc container lint

# Note: do NOT add a CMD/ENTRYPOINT — bootc boots the OS, it doesn't run a process.
