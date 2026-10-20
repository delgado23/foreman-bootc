# Build Proxmox VMs with their EFI disk, Secure Boot and a VirtIO RNG from the
# start, and give their host groups the shim (Secure Boot) PXE loader.
#
# Why all three are needed:
#  * An efidisk0 (efitype=4m) moves the VM from Proxmox's frozen 2 MB OVMF
#    (edk2 2023.02) to the current 4 MB OVMF. Since PVE 8.4 that firmware turns
#    off its network stack when the guest has no random number generator, and
#    x86-64-v3 exposes no RDRAND/RDSEED. Without rng0 it never PXEs at all:
#    "BdsDxe: No bootable option or device was found".
#  * is_secure_boot=1 makes foreman_fog_proxmox create that efidisk itself
#    (4m, Microsoft keys pre-enrolled), so nothing has to add it after install.
#  * With Secure Boot on, the firmware refuses the "Grub2 UEFI" loader
#    (grubx64.efi is signed only by AlmaLinux). "Grub2 UEFI SecureBoot" serves
#    the Microsoft-signed shim, which trusts the AlmaLinux CA that signs grub
#    and the installer kernels. Shim also boots fine with Secure Boot off.
#
# The plugin has no form field for rng0; it reaches Proxmox because unknown
# config_attributes keys pass straight through to the create call. Saving one
# of these compute profiles in the Foreman UI may drop it, so re-run this
# script after any UI edit.
#
# The Kubernetes profiles get the same settings. Their host groups (29/30)
# inherit the PXE loader from AlmaLinux 10 (24); the first version of this
# script pinned them to "Grub2 UEFI", so they are set back to inherit here.
# kubernetes-cluster-provisioning's proxmox_postconfig reads the VM config and
# only adds efidisk0/rng0 when a profile did not create them.
#
# Run on Foreman (idempotent, prints before -> after):
#   sudo foreman-rake console < foreman/setup_proxmox_firmware.rb
# Dry run, changes nothing:
#   { echo "ENV['FW_DRY_RUN']='1'"; cat foreman/setup_proxmox_firmware.rb; } | sudo foreman-rake console
# Only some compute profiles, host groups untouched (e.g. a throwaway test copy):
#   { echo "ENV['FW_PROFILES']='Proxmox-Small-SB-test'"; echo "ENV['FW_HOSTGROUPS']='0'"; cat foreman/setup_proxmox_firmware.rb; } | sudo foreman-rake console
# Roll back to the original state (Secure Boot off, no rng0, Grub2 UEFI everywhere):
#   { echo "ENV['FW_ROLLBACK']='1'"; cat foreman/setup_proxmox_firmware.rb; } | sudo foreman-rake console
# NB: foreman-rake console evaluates piped stdin line by line, so keep method
# chains on one line (a leading-dot continuation would split them).
User.current = User.unscoped.find_by!(login: 'admin')
DRY_RUN  = ENV['FW_DRY_RUN'] == '1'
ROLLBACK = ENV['FW_ROLLBACK'] == '1'
PROFILES = (ENV['FW_PROFILES'] || 'Proxmox-Small,Proxmox-Medium,Kubernetes Worker Node,Kubernetes Controlplane Node').split(',').map(&:strip)
DO_HOSTGROUPS = ENV['FW_HOSTGROUPS'] != '0'
RNG0 = 'source=/dev/urandom'
SB_LOADER = 'Grub2 UEFI SecureBoot'
OLD_LOADER = 'Grub2 UEFI'
puts "MODE\t#{ROLLBACK ? 'rollback' : 'apply'}#{DRY_RUN ? ' (dry run)' : ''}"

# The rng0 pass-through and the is_secure_boot -> efidisk0 behaviour were read
# from foreman_fog_proxmox 1.0.0; re-check both before trusting another series.
plugin = Gem.loaded_specs['foreman_fog_proxmox']&.version
raise "foreman_fog_proxmox #{plugin.inspect} not 1.0.x; re-verify parsed_typed_config and process_firmware_attributes first" unless plugin && plugin.segments.first(2) == [1, 0]
puts "VERSIONS\tforeman=#{SETTINGS[:version]}\tforeman_fog_proxmox=#{plugin}"

cr = ComputeResource.unscoped.find_by!(name: 'Proxmox')

# Resolve and validate everything before writing anything, so a bad or missing
# profile or host group can't leave a partial change behind; the writes then
# happen in one transaction.
profile_plans = PROFILES.map do |pname|
  cp = ComputeProfile.unscoped.find_by!(name: pname)
  ca = ComputeAttribute.unscoped.find_by!(compute_resource_id: cr.id, compute_profile_id: cp.id)
  attrs = ca.vm_attrs.deep_dup
  cfg = attrs['config_attributes'] ||= {}
  raise "#{pname}: expected bios=ovmf, found #{cfg['bios'].inspect}" unless cfg['bios'] == 'ovmf'
  before = { 'is_secure_boot' => cfg['is_secure_boot'], 'rng0' => cfg['rng0'] }
  if ROLLBACK
    cfg['is_secure_boot'] = '0'
    cfg.delete('rng0')
  else
    cfg['is_secure_boot'] = '1'
    cfg['rng0'] = RNG0
  end
  after = { 'is_secure_boot' => cfg['is_secure_boot'], 'rng0' => cfg['rng0'] }
  { name: pname, ca: ca, attrs: attrs, before: before, after: after }
end

# id => [loader when applied, loader when rolled back]; '' means inherit.
HG_LOADERS = { 22 => [SB_LOADER, OLD_LOADER], 24 => [SB_LOADER, OLD_LOADER], 29 => ['', ''], 30 => ['', ''] }
hostgroup_plans = (DO_HOSTGROUPS ? HG_LOADERS : {}).map do |hg_id, (applied, previous)|
  hg = Hostgroup.unscoped.find(hg_id)
  { hg: hg, have: hg.read_attribute(:pxe_loader).to_s, want: ROLLBACK ? previous : applied }
end

ActiveRecord::Base.transaction do
  profile_plans.each do |pl|
    if pl[:before] == pl[:after]
      puts "PROFILE\t#{pl[:name]}\tunchanged\t#{pl[:after].to_json}"
      next
    end
    unless DRY_RUN
      pl[:ca].vm_attrs = pl[:attrs]
      pl[:ca].save!
    end
    puts "PROFILE\t#{pl[:name]}\t#{pl[:before].to_json} -> #{pl[:after].to_json}"
  end

  hostgroup_plans.each do |pl|
    if pl[:have] == pl[:want]
      puts "HOSTGROUP\t#{pl[:hg].title}\tunchanged\t#{pl[:want].inspect}"
      next
    end
    unless DRY_RUN
      pl[:hg].pxe_loader = pl[:want]
      pl[:hg].save!
    end
    puts "HOSTGROUP\t#{pl[:hg].title}\t#{pl[:have].inspect} -> #{pl[:want].inspect}"
  end
end

if DO_HOSTGROUPS
  # Hosts that store no loader follow their host group the next time Foreman
  # rewrites their DHCP/TFTP records. Shim boots with Secure Boot on or off,
  # so this is harmless, but list them so the change is visible.
  Host::Managed.unscoped.where(hostgroup_id: Hostgroup.unscoped.find(22).subtree_ids + Hostgroup.unscoped.find(24).subtree_ids, pxe_loader: [nil, '']).order(:name).each do |h|
    puts "INHERITS\t#{h.name}\thostgroup=#{h.hostgroup&.title}\teffective=#{h.pxe_loader.inspect}"
  end
end
exit
