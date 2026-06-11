== Garaventaville AlmaLinux 10 bootc — Raspberry Pi ==

This card was written from the almalinux10-bootc-rpi image (image mode / bootc).
After first boot, OS updates come from `bootc upgrade` pulling the container from
Katello — you do NOT dnf-update or re-flash for normal updates.

Before inserting the card into the Pi, customize the seed on the CIDATA partition:

  user-data        cloud-config (set `hostname:`; add SSH keys only if you want a
                   login user — root management keys are already baked in).
  network-config   OPTIONAL netplan v2 for a static address (servers need one).
                   Example:
                       version: 2
                       ethernets:
                         end0:
                           dhcp4: false
                           addresses: [172.16.0.4/23]
                           routes:
                             - to: default
                               via: 172.16.0.1
                           nameservers:
                             addresses: [172.16.0.2, 172.16.0.6]

Then move the card to the Pi and boot. On first boot cloud-init applies the seed
and grows the root filesystem to fill the card.

Default management access is as root via the baked-in Foreman rex / Ascender keys.
