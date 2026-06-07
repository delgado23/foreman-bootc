User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

# 1. Release locks held by the stuck CreateContainerPushRoot task
tid = '4cacff99-b8fe-4256-bd70-36137f663b24'
t = ForemanTasks::Task.where(id: tid).first
if t
  n = ForemanTasks::Lock.where(task_id: t.id).delete_all
  begin; t.update_columns(state: 'stopped', result: 'error'); rescue; end
  puts "TASK_CLEANED\tlocks_deleted=#{n}\tstate=#{t.reload.state}"
end

# 2. Belt-and-suspenders: clear any locks still pinned to these resources
[['Katello::Product', 33], ['Katello::RootRepository', 150]].each do |rt, rid|
  m = ForemanTasks::Lock.where(resource_type: rt, resource_id: rid).delete_all
  puts "LOCKS\t#{rt}\t#{rid}\tdeleted=#{m}"
end

# 3. Remove dangling root repository, then the broken product
prod = Katello::Product.where(organization_id: org.id, label: 'bootc').first
if prod
  prod.root_repositories.to_a.each do |rr|
    begin; rr.destroy!; puts "ROOTREPO_DESTROYED\t#{rr.id}"
    rescue => e; puts "ROOTREPO_ERR\t#{rr.id}\t#{e.class}: #{e.message.to_s[0,140]}"; end
  end
  begin; prod.reload.destroy!; puts "PRODUCT_DESTROYED\t#{prod.id}"
  rescue => e; puts "PRODUCT_ERR\t#{e.class}: #{e.message.to_s[0,160]}"; end
end

puts "REMAINING_PRODUCTS\t#{Katello::Product.where(organization_id: org.id, label: 'bootc').count}"
puts "REMAINING_ROOTREPOS\t#{Katello::RootRepository.where('name LIKE ?', '%bootc%').count}"
exit
