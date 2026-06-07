# Verify provisioning-template resolution using Foreman's own resolver, for a
# host in the Image Mode group (-> bootc) vs the parent RPM group / no group
# (-> stock). No real host needed.
def resolve(kind, os_id, hg_id)
  t = ProvisioningTemplate.find_template(kind: kind, operatingsystem_id: os_id, hostgroup_id: hg_id)
  t&.name || '(none)'
end

scenarios = {
  'IMAGE_MODE_hg31' => 31,   # AlmaLinux 10/Image Mode -> expect bootc templates
  'RPM_parent_hg24' => 24,   # AlmaLinux 10            -> expect stock
  'NO_HOSTGROUP'    => nil,  # OS default              -> expect stock
}
[49, 51].each do |os|
  scenarios.each do |label, hg|
    puts "#{label}\tos=#{os}\tprovision=#{resolve('provision', os, hg)}\tPXEGrub2=#{resolve('PXEGrub2', os, hg)}"
  end
end
exit
