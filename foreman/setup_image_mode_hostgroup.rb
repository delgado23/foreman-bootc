# Make bootc (image mode) an OPT-IN build profile via a host group, and restore
# RPM as the default for AlmaLinux 10. Toggle build mode by host group choice.
User.current = User.unscoped.find_by!(login: 'admin')
org  = Organization.unscoped.find(4)

# 1. Host group "Image Mode" nested under "AlmaLinux 10" (id 24) to inherit infra.
# Foreman uses the ancestry gem for hierarchy (set via #parent=, not parent_id).
parent = Hostgroup.unscoped.find(24)
hg = parent.children.find_by(name: 'Image Mode') || Hostgroup.unscoped.new(name: 'Image Mode')
hg.parent = parent
hg.organizations = parent.organizations
hg.locations = parent.locations
hg.save!
puts "HOSTGROUP\tid=#{hg.id}\ttitle=#{hg.title}"

# 2. bootc host-group parameters (hosts inherit these)
{
  'ostreecontainer' => 'foreman.garaventaville.com/garaventaville/bootc/almalinux10-bootc:10.0',
  'ansible_pkg_mgr' => 'dnf',
  'kt_activation_keys' => 'AlmaLinux 10',
}.each do |k, v|
  p = hg.group_parameters.find_or_initialize_by(name: k)
  p.value = v
  p.save!
  puts "HGPARAM\t#{k}=#{v}"
end

# 3. Bind the bootc templates to this host group (template combinations)
[258, 259].each do |tid|
  t = ProvisioningTemplate.unscoped.find(tid)
  tc = t.template_combinations.find_or_initialize_by(hostgroup_id: hg.id)
  tc.save!
  puts "COMBINATION\t#{t.name}\t->\thg=#{hg.title}"
end

# 4. Restore stock RPM templates as the AlmaLinux 10 OS default
prov = TemplateKind.find_by(name: 'provision')
pxe  = TemplateKind.find_by(name: 'PXEGrub2')
stock = { prov.id => 58, pxe.id => 8 }  # Kickstart default / Kickstart default PXEGrub2
[49, 51].each do |osid|
  os = Operatingsystem.find(osid)
  stock.each do |kind_id, tpl_id|
    odt = os.os_default_templates.find_or_initialize_by(template_kind_id: kind_id)
    odt.provisioning_template_id = tpl_id
    odt.save!
    puts "OSDEFAULT\t#{os.fullname}\t#{ProvisioningTemplate.find(tpl_id).name}"
  end
end
exit
