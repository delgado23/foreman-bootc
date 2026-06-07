# Loads the bootc provisioning + PXEGrub2 templates into Foreman and sets them
# as the OS default for both AlmaLinux 10 OS records. Idempotent (find_or_init).
User.current = User.unscoped.find_by!(login: 'admin')

org  = Organization.unscoped.find_by!(name: 'Garaventaville')
locs = Location.unscoped.where(id: [3, 5]).to_a
oses = Operatingsystem.unscoped.where(id: [49, 51]).to_a

defs = [
  { name: 'AlmaLinux 10 bootc Kickstart', kind: 'provision', file: '/tmp/kickstart_almalinux10_bootc.erb' },
  { name: 'AlmaLinux 10 bootc PXEGrub2',  kind: 'PXEGrub2',  file: '/tmp/pxegrub2_almalinux10_bootc.erb' },
]

created = []
defs.each do |d|
  kind = TemplateKind.find_by!(name: d[:kind])
  tpl  = ProvisioningTemplate.unscoped.find_or_initialize_by(name: d[:name])
  tpl.template         = File.read(d[:file])
  tpl.template_kind    = kind
  tpl.snippet          = false
  tpl.organizations    = [org]
  tpl.locations        = locs
  tpl.operatingsystems = oses
  tpl.save!
  created << tpl
  puts "RESULT\tsaved\tid=#{tpl.id}\t#{tpl.name}\t(#{kind.name})"
end

oses.each do |os|
  created.each do |t|
    odt = os.os_default_templates.find_or_initialize_by(template_kind_id: t.template_kind_id)
    odt.provisioning_template_id = t.id
    odt.save!
    puts "RESULT\tdefault\t#{os.fullname}\t->\t#{t.name}"
  end
end
puts "RESULT\tDONE"
exit
