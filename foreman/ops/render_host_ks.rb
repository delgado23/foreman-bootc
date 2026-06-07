# Render the provision template for the in-flight bootc host and dump the lines
# around the parse error to see what leaked into the command section.
host = Host::Managed.unscoped.where(hostgroup_id: 31).order(created_at: :desc).first
host ||= Host::Managed.unscoped.where(build: true).order(created_at: :desc).first
puts "HOST\t#{host&.id}\t#{host&.name}\thg=#{host&.hostgroup&.title}\tbuild=#{host&.build}"
template = host.provisioning_template(kind: 'provision')
puts "TEMPLATE\t#{template&.name}"
begin
  content = host.render_template(template: template)
  content.split("\n").each_with_index do |l, i|
    puts "L#{i + 1}: #{l}" if (i + 1).between?(1, 30)
  end
rescue => e
  puts "RENDER_ERR\t#{e.class}: #{e.message.to_s[0,200]}"
end
exit
