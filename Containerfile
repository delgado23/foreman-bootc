# AlmaLinux 10 image-mode (bootc) base.
# Verify the tag resolves before relying on it:  podman pull quay.io/almalinuxorg/almalinux-bootc:10
FROM quay.io/almalinuxorg/almalinux-bootc:10

# --- Metadata --------------------------------------------------------------
LABEL org.opencontainers.image.title="almalinux10-bootc" \
      org.opencontainers.image.description="AlmaLinux 10 image-mode base for Garaventaville fleet" \
      org.opencontainers.image.vendor="garaventaville"

# --- Packages baked into the image -----------------------------------------
# Everything a host needs goes here, NOT into per-host kickstart. Rebuild +
# re-push to ship changes; hosts pick them up via `bootc upgrade`.
RUN dnf -y install \
        subscription-manager \
        qemu-guest-agent \
        vim-enhanced \
        tmux \
        bash-completion \
        cloud-init \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/lib/dnf/history.sqlite* \
              /var/log/dnf* /var/log/hawkey.log

# subscription-manager is NOT in the AlmaLinux bootc base, but Foreman/Katello
# registration (the %post redhat_register snippet) needs it to register the host
# and upload the bootc facts that mark it as an image-mode host. firewalld is
# likewise absent — the bootc kickstart omits the `firewall` directive rather
# than installing it (manage host firewall in the image if you want one).

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
