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

# --- Config baked into the image (example) ---------------------------------
# Drop-in files, sysctls, etc. live in the image so they're immutable per host.
# COPY etc/ /etc/

# Clean build leftovers from /tmp and /var/tmp. We deliberately do NOT touch
# /run: bootc mounts it as tmpfs at boot (build-time content is masked anyway),
# and buildah keeps live mounts there (/run/secrets, /run/.containerenv) that
# can't be removed. The cosmetic 'nonempty-run-tmp' lint warning is harmless.
RUN rm -rf /tmp/* /var/tmp/*

# bootc requires a valid, bootable image. Validate the layout at build time:
RUN bootc container lint

# Note: do NOT add a CMD/ENTRYPOINT — bootc boots the OS, it doesn't run a process.
