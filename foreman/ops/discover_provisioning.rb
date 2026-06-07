org = Organization.unscoped.find(4)
puts "--- compute resources ---"
ComputeResource.unscoped.each { |c| puts "CR\t#{c.id}\t#{c.name}\t#{c.provider}" }
puts "--- subnets (tftp/dhcp) ---"
Subnet.unscoped.each { |s| puts "SUBNET\t#{s.id}\t#{s.name}\t#{s.network}\ttftp=#{s.tftp_id.present?}\tdhcp=#{s.dhcp_id.present?}" }
puts "--- activation keys (org) ---"
Katello::ActivationKey.where(organization_id: org.id).each { |k| puts "AK\t#{k.id}\t#{k.name}\tcv=#{k.content_view&.name}\tenv=#{k.environment&.name}" }
puts "--- partition tables (redhat) ---"
Ptable.unscoped.where("name LIKE '%Kickstart%' OR name LIKE '%bootc%'").each { |p| puts "PTABLE\t#{p.id}\t#{p.name}" }
puts "--- bootc repo pull auth ---"
r = Katello::Repository.find(23216)
puts "REPO_PULL\tunauthenticated_pull=#{r.root.respond_to?(:unauthenticated_pull) ? r.root.unauthenticated_pull : 'n/a'}"
puts "--- domains ---"
Domain.unscoped.each { |d| puts "DOMAIN\t#{d.id}\t#{d.name}" }
exit
