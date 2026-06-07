User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)
prod = Katello::Product.where(organization_id: org.id, label: 'bootc').first
puts "PRODUCT\tid=#{prod.id}\tcp_id=#{prod.cp_id}\trepos=#{prod.repositories.count}"
prod.repositories.each do |r|
  puts "REPO\tid=#{r.id}\tpull_path=#{r.container_repository_name}\ttype=#{r.content_type}"
  begin
    tags = r.docker_tags.pluck(:name) rescue []
    puts "TAGS\t#{tags.join(', ')}"
    puts "MANIFESTS\t#{r.docker_manifests.count}"
  rescue => e
    puts "TAGINFO_ERR\t#{e.class}: #{e.message.to_s[0,120]}"
  end
end
exit
