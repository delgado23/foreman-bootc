# Make bootc (image mode) an opt-in profile for the aarch64 / Raspberry Pi fleet,
# mirroring foreman/setup_image_mode_hostgroup.rb (which does this for x86_64).
#
# Run on foreman:  sudo foreman-rake console < foreman/setup_rpi_image_mode_hostgroup.rb
#
# DIFFERENCES from the x86 script (and why this is its own, smaller script):
#   * Nests under "AlmaLinux 10 aarch64" (id 21), NOT "AlmaLinux 10" (id 24). That
#     parent already supplies everything by inheritance — arch=aarch64, os 10.2,
#     Production / AlmaLinux_10_aarch64 CV, content source, domain/subnet, and
#     kt_activation_keys="AlmaLinux 10 aarch64" — so the child only overrides the
#     bootc-specific host parameters.
#   * NO provisioning-template binding and NO OS-default juggling. Pis are FLASHED
#     from a .raw (build-rpi-image.sh), not PXE/Anaconda/kickstart provisioned, so
#     the bootc Kickstart/PXEGrub2 templates don't apply here.
#   * The ostreecontainer ref resolves the rpi image's PRODUCTION pull path (the
#     smoke-test-gated, anonymously-pullable env), not the raw Library push path —
#     pulling the Library path fails with "authentication required" (Library has
#     registry_unauthenticated_pull=false). See [[bootc-content-view-gating]].
# Idempotent (find-or-create + find-or-initialize params).
User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

# 1. Host group "Image Mode" nested under "AlmaLinux 10 aarch64" (id 21) to inherit
# infra. Foreman uses the ancestry gem for hierarchy (set via #parent=, not parent_id).
parent = Hostgroup.unscoped.find(21)
hg = parent.children.find_by(name: 'Image Mode') || Hostgroup.unscoped.new(name: 'Image Mode')
hg.parent = parent
hg.organizations = parent.organizations
hg.locations = parent.locations
hg.save!
puts "HOSTGROUP\tid=#{hg.id}\ttitle=#{hg.title}"

# 2. Resolve the rpi image's promoted PRODUCTION registry path from Katello rather
# than hardcoding it (the env/CV-qualified path is owned by Katello). Floating major
# tag: hosts track :10 and auto-follow the latest gated point release.
TAG  = '10'
cv   = Katello::ContentView.find_by!(organization_id: org.id, label: 'bootc')
prod = Katello::KTEnvironment.find_by!(organization_id: org.id, label: 'Production')
# NB single line: foreman-rake console evaluates piped stdin line-by-line, so a
# leading-dot continuation would split the chain and break the lookup.
repo = Katello::Repository.in_environment(prod).in_content_views([cv]).detect { |r| r.root&.name == 'almalinux10-bootc-rpi' }
raise "almalinux10-bootc-rpi not promoted to Production yet — publish+promote the bootc CV first" if repo.nil?
ostree_ref = "foreman.garaventaville.com/#{repo.container_repository_name}:#{TAG}"
puts "OSTREE_REF\t#{ostree_ref}"

# 3. bootc host-group parameters (hosts inherit these). kt_activation_keys is already
# inherited from the parent as "AlmaLinux 10 aarch64"; set explicitly here too so the
# group is self-documenting and independent of parent edits (matches the x86 script).
{
  'ostreecontainer' => ostree_ref,
  'ansible_pkg_mgr' => 'dnf',
  'kt_activation_keys' => 'AlmaLinux 10 aarch64',
}.each do |k, v|
  p = hg.group_parameters.find_or_initialize_by(name: k)
  p.value = v
  p.save!
  puts "HGPARAM\t#{k}=#{v}"
end
exit
