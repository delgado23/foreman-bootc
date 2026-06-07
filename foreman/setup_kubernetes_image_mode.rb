# Convert the Kubernetes host groups to image-mode (bootc) IN PLACE.
#
#   29  AlmaLinux 10/Kubernetes Controlplane Node  -> kubernetes-controlplane image
#   30  AlmaLinux 10/Kubernetes Worker Node        -> kubernetes-worker image
#
# Converting in place (rather than new groups under "Image Mode") keeps the group
# titles — and therefore the Ansible inventory group names the
# kubernetes-cluster-provisioning playbook targets
# (foreman_almalinux10_kubernetes{controlplane,worker}node) — unchanged.
#
# Mirrors foreman/setup_image_mode_hostgroup.rb: adds the bootc host-group params
# and binds the bootc provisioning template combinations (provision id 258,
# PXEGrub2 id 259). The activation key (AlmaLinux 10 Kubernetes) is left as-is.
#
# Run on foreman:  sudo foreman-rake console < setup_kubernetes_image_mode.rb
User.current = User.unscoped.find_by!(login: 'admin')

REGISTRY = 'foreman.garaventaville.com/garaventaville/bootc'.freeze
TAG      = ENV.fetch('K8S_TAG', '1.35.5')

groups = {
  29 => "#{REGISTRY}/kubernetes-controlplane:#{TAG}",
  30 => "#{REGISTRY}/kubernetes-worker:#{TAG}",
}

groups.each do |hg_id, image|
  hg = Hostgroup.unscoped.find(hg_id)
  puts "HOSTGROUP\tid=#{hg.id}\ttitle=#{hg.title}"

  # bootc host-group parameters (hosts inherit these). kt_activation_keys is
  # left untouched (stays 'AlmaLinux 10 Kubernetes').
  {
    'ostreecontainer'           => image,
    'ansible_pkg_mgr'           => 'dnf',
    'remote_execution_ssh_user' => 'root',
  }.each do |k, v|
    p = hg.group_parameters.find_or_initialize_by(name: k)
    p.value = v
    p.save!
    puts "HGPARAM\t#{k}=#{v}"
  end

  # Bind the bootc provisioning templates to this host group.
  [258, 259].each do |tid|
    t = ProvisioningTemplate.unscoped.find(tid)
    tc = t.template_combinations.find_or_initialize_by(hostgroup_id: hg.id)
    tc.save!
    puts "COMBINATION\t#{t.name}\t->\thg=#{hg.title}"
  end

  # Report (do not auto-change) the partition table. The bootc kickstart's
  # `ostreecontainer` does its own OS-disk layout, so an RPM-era custom PT on the
  # worker group ("Kubernetes Worker Kickstart") may be redundant or conflict.
  # If provisioning fails on partitioning, clear it manually:
  #   hg.ptable = nil; hg.save!
  puts "PTABLE\t#{hg.ptable&.name.inspect} (review for image-mode; clear if it conflicts)"
end
exit
