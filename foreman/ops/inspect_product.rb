User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)
p = Katello::Product.where(organization_id: org.id, label: 'bootc').first
if p.nil?
  puts "NONE"
else
  puts "PROD\tid=#{p.id}\tlabel=#{p.label}\tcp_id=#{p.cp_id.inspect}\tprovider=#{p.provider&.name.inspect}\trepos=#{p.repositories.count}"
  p.repositories.each { |r| puts "REPO\tid=#{r.id}\tname=#{r.container_repository_name}\tpulp=#{r.version_href.inspect}" }
end
# compare to a known-good product for reference
g = Katello::Product.where(organization_id: org.id, label: 'AlmaLinux_10').first
puts "REF_GOOD\tlabel=AlmaLinux_10\tcp_id=#{g&.cp_id.inspect}" if g
exit
