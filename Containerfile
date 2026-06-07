# AlmaLinux 10 image-mode (bootc) base.
# Verify the tag resolves before relying on it:  podman pull quay.io/almalinuxorg/almalinux-bootc:10
FROM quay.io/almalinuxorg/almalinux-bootc:10

# --- Metadata --------------------------------------------------------------
LABEL org.opencontainers.image.title="almalinux10-bootc" \
      org.opencontainers.image.description="AlmaLinux 10 image-mode base for Garaventaville fleet" \
      org.opencontainers.image.vendor="garaventaville"

# --- EPEL + CRB -------------------------------------------------------------
# htop/btop/nmon/atop/certbot/duo_unix/git-credential-oauth live in EPEL, which
# needs CRB enabled. epel-release ships the repo + GPG key into the image.
RUN dnf -y install epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf clean all

# --- Packages baked into the image -----------------------------------------
# Everything a host needs goes here, NOT into per-host kickstart. Rebuild +
# re-push to ship changes; hosts pick them up via `bootc upgrade`.
RUN dnf -y install \
        subscription-manager \
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
        certbot \
        python3-certbot-dns-cloudflare \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/lib/dnf/history.sqlite* \
              /var/log/dnf* /var/log/hawkey.log

# subscription-manager is NOT in the AlmaLinux bootc base, but Foreman/Katello
# registration (the %post redhat_register snippet) needs it to register the host
# and upload the bootc facts that mark it as an image-mode host. firewalld is
# likewise absent — the bootc kickstart omits the `firewall` directive rather
# than installing it (manage host firewall in the image if you want one).

# --- katello-host-tools (Foreman client repo, not in AlmaLinux repos) -------
# Uploads the package profile + enabled repos to Katello (clears the "no
# packages reported" errata warning) and adds the rhsm content plugins. Pulled
# transiently via --repofrompath so the image ships no external .repo file; the
# Foreman GPG key is auto-imported by dnf -y. Bump 3.18/el10 with your versions.
RUN dnf -y \
        --repofrompath 'foreman-client,https://yum.theforeman.org/client/3.18/el10/x86_64' \
        --setopt=foreman-client.gpgcheck=1 \
        --setopt=foreman-client.gpgkey=https://yum.theforeman.org/releases/3.18/RPM-GPG-KEY-foreman \
        install katello-host-tools katello-host-tools-tracer \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/lib/dnf/history.sqlite* /var/log/dnf* /var/log/hawkey.log

# --- Services --------------------------------------------------------------
RUN systemctl enable qemu-guest-agent sshd

# --- Foreman remote execution (SSH as root) --------------------------------
# %post key injection lands under /var (/root -> var/roothome, /home -> var/home)
# and does NOT survive the bootc first-boot /var init, so trust the proxy's rex
# public key from /usr instead. Pair with host-group param
# remote_execution_ssh_user=root so rex connects as root directly (no sudo user).
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
