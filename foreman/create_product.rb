User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

product = ::Katello::Product.new(name: 'bootc')
begin
  ForemanTasks.sync_task(::Actions::Katello::Product::Create, product, org)
  product.reload
  puts "NEW_PRODUCT\tid=#{product.id}\tlabel=#{product.label}\tcp_id=#{product.cp_id.inspect}\tprovider=#{product.provider&.name.inspect}"
rescue => e
  puts "CREATE_ERR\t#{e.class}: #{e.message.to_s[0,400]}"
end
exit
