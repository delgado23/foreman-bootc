# Create the 'AlmaLinux 10 aarch64' activation key the Pi build registers with.
#
# Run on foreman:  sudo foreman-rake console < foreman/setup_aarch64_activation_key.rb
#
# Idempotent (find-or-create). The key only has to put the transient build
# consumer into an environment/CV that exposes the freshly-synced aarch64 RPM
# repos. Under Simple Content Access the Library + Default Organization View
# combination exposes ALL synced Library content, so the build's explicit
# `dnf --enablerepo='Garaventaville_aarch64_AlmaLinux_10_*'` (see Containerfile.rpi)
# is what actually selects the repos — we do NOT need per-repo content overrides
# here, exactly as the x86 'AlmaLinux 10' key works today.
#
# PREREQUISITE: the aarch64 product + repos must already exist and be synced —
# see RPI-KATELLO.md (hammer commands). Run foreman/ops/inspect_almalinux_content.rb
# first to confirm the env/CV the x86 key uses, if you'd rather mirror it than
# use Default Org View.
User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

NAME = 'AlmaLinux 10 aarch64'

# Library + Default Organization View == "all synced Library content" under SCA.
lib    = Katello::KTEnvironment.find_by!(organization_id: org.id, library: true)
defcv  = Katello::ContentView.find_by!(organization_id: org.id, default: true)

ak = Katello::ActivationKey.find_or_initialize_by(organization_id: org.id, name: NAME)
new_key = ak.new_record?
ak.environment    = lib
ak.content_view   = defcv
ak.unlimited_hosts = true
ak.save!
puts "#{new_key ? 'AK_CREATED' : 'AK_EXISTS'}\tid=#{ak.id}\tname=#{ak.name.inspect}\t" \
     "env=#{ak.environment&.label.inspect}\tcv=#{ak.content_view&.label.inspect}\t" \
     "unlimited=#{ak.unlimited_hosts}"

# Sanity: is the aarch64 product synced into Library yet (so the key can see it)?
prod = Katello::Product.where(organization_id: org.id, label: 'aarch64_AlmaLinux_10').first
if prod.nil?
  puts "WARN\tproduct 'aarch64_AlmaLinux_10' not found — create + sync it first (RPI-KATELLO.md)."
else
  synced = prod.repositories.in_default_view.select { |r| (r.content_counts['rpm'].to_i rescue 0) > 0 }
  puts "PRODUCT_OK\tid=#{prod.id}\trepos=#{prod.repositories.count}\twith_rpms=#{synced.count}"
  prod.root_repositories.order(:id).each do |rr|
    puts "  REPO\t#{rr.label}\tcontent_label=#{org.label}_#{prod.label}_#{rr.label}"
  end
end
exit
