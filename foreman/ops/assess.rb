User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

puts "--- products labelled bootc ---"
Katello::Product.where(organization_id: org.id, label: 'bootc').each do |p|
  puts "PROD\tid=#{p.id}\tcp_id=#{p.cp_id.inspect}\troot_repos=#{p.root_repositories.count}\trepos=#{p.repositories.count}"
  p.root_repositories.each { |rr| puts "ROOTREPO\tid=#{rr.id}\tname=#{rr.name}\tlabel=#{rr.label}" }
end

puts "--- any container repos mentioning bootc ---"
Katello::RootRepository.where("name LIKE ? OR label LIKE ?", "%bootc%", "%bootc%").each do |rr|
  puts "RR\tid=#{rr.id}\tprod=#{rr.product_id}\tname=#{rr.name}"
end

puts "--- running/paused tasks (locks) ---"
ForemanTasks::Task.where(state: %w[running paused]).order(started_at: :desc).limit(15).each do |t|
  puts "TASK\tid=#{t.id}\tlabel=#{t.label}\tstate=#{t.state}\tresult=#{t.result}\tstarted=#{t.started_at}"
end
exit
