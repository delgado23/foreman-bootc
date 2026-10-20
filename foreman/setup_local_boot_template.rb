# Shorten the GRUB menu wait for hosts that PXE-boot into Foreman's local-boot
# config on every reboot.
#
# Built hosts whose Proxmox boot order puts the network first (new builds, with
# efidisk0 + rng0) PXE on every boot; Foreman then serves the "PXEGrub2 default
# local boot" template, which waits 20 s at its menu before handing off to the
# disk. That template is locked, so this clones it with only the timeout
# changed and points the local_boot_PXEGrub2 setting at the clone. The menu
# entries still come from the stock pxegrub2_chainload/pxegrub2_discovery
# snippets.
#
# The clone is derived from the stock template each run (exactly one
# "set timeout=20" is replaced), so re-run it after a Foreman upgrade changes
# the stock template. Existing hosts keep the TFTP config rendered when they
# were last built until Foreman rewrites it (rebuild config, or the next build).
#
# Run on Foreman (idempotent, prints before -> after):
#   sudo foreman-rake console < foreman/setup_local_boot_template.rb
# Dry run, changes nothing:
#   { echo "ENV['LB_DRY_RUN']='1'"; cat foreman/setup_local_boot_template.rb; } | sudo foreman-rake console
# Roll back (point the setting at the stock template again; the clone is kept):
#   { echo "ENV['LB_ROLLBACK']='1'"; cat foreman/setup_local_boot_template.rb; } | sudo foreman-rake console
# NB: foreman-rake console evaluates piped stdin line by line, so keep method
# chains on one line (a leading-dot continuation would split them).
User.current = User.unscoped.find_by!(login: 'admin')
DRY_RUN  = ENV['LB_DRY_RUN'] == '1'
ROLLBACK = ENV['LB_ROLLBACK'] == '1'
STOCK_NAME = 'PXEGrub2 default local boot'
CLONE_NAME = 'PXEGrub2 local boot (3s timeout)'
TIMEOUT = 3
SETTING = 'local_boot_PXEGrub2'
puts "MODE\t#{ROLLBACK ? 'rollback' : 'apply'}#{DRY_RUN ? ' (dry run)' : ''}"

stock = ProvisioningTemplate.unscoped.find_by!(name: STOCK_NAME)
raise "#{STOCK_NAME}: expected exactly one 'set timeout=20'" unless stock.template.scan(/^set timeout=20$/).size == 1
body = stock.template.sub(/^set timeout=20$/, "set timeout=#{TIMEOUT}")
body = body.sub("name: #{STOCK_NAME}\n", "name: #{CLONE_NAME}\n")
body = body.sub("  Do not associate or change the name.\n", "  Clone of \"#{STOCK_NAME}\" with a #{TIMEOUT} s menu timeout, managed by\n  foreman-bootc foreman/setup_local_boot_template.rb; re-run that to refresh it.\n")

# The local boot template is looked up by name, which can be scoped to the
# current organization/location, so give the clone the stock template's
# taxonomies plus every location of the Garaventaville organization.
org = Organization.unscoped.find_by!(name: 'Garaventaville')
orgs = (stock.organizations.to_a + [org]).uniq
locs = (stock.locations.to_a + org.locations.to_a).uniq

unless ROLLBACK
  clone = ProvisioningTemplate.unscoped.find_by(name: CLONE_NAME)
  state = clone.nil? ? 'create' : (clone.template == body && clone.organizations.to_a.sort_by(&:id) == orgs.sort_by(&:id) && clone.locations.to_a.sort_by(&:id) == locs.sort_by(&:id) ? 'unchanged' : 'update')
  unless DRY_RUN || state == 'unchanged'
    clone ||= ProvisioningTemplate.new(name: CLONE_NAME)
    clone.template_kind = stock.template_kind
    clone.snippet = false
    clone.locked = false
    clone.template = body
    clone.organizations = orgs
    clone.locations = locs
    clone.save!
  end
  puts "TEMPLATE\t#{CLONE_NAME}\t#{state}\ttimeout=#{TIMEOUT}\torgs=#{orgs.map(&:name).join(',')}\tlocs=#{locs.map(&:name).join(',')}"
end

want = ROLLBACK ? STOCK_NAME : CLONE_NAME
have = Setting[SETTING]
if have == want
  puts "SETTING\t#{SETTING}\tunchanged\t#{want.inspect}"
else
  Setting[SETTING] = want unless DRY_RUN
  puts "SETTING\t#{SETTING}\t#{have.inspect} -> #{want.inspect}"
end

# A host or global parameter of the same name overrides the setting.
overrides = Parameter.where(name: [SETTING, SETTING.downcase]).map { |p| "#{p.type}:#{p.reference_id}=#{p.value}" }
puts "OVERRIDES\t#{overrides.empty? ? 'none' : overrides.join(' ')}"
exit
