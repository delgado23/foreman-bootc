# Read-only. Dump the existing x86_64 AlmaLinux RPM content + the 'AlmaLinux 10'
# activation key, so the aarch64 siblings can be created to MATCH exactly
# (same repo set, download policy, GPG, and the env/CV the build registers into).
#
# Run on foreman:  sudo foreman-rake console < foreman/ops/inspect_almalinux_content.rb
#
# Feeds RPI-KATELLO.md / setup_aarch64_activation_key.rb. Makes no changes.
User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

puts "=== candidate RPM products (org #{org.name}) ==="
Katello::Product.where(organization_id: org.id)
                .where("label ILIKE ? OR name ILIKE ?", "%alma%", "%alma%").order(:id).each do |p|
  puts "PRODUCT\tid=#{p.id}\tname=#{p.name.inspect}\tlabel=#{p.label}\trepos=#{p.repositories.count}"
end

# The x86 build enables Garaventaville_AlmaLinux_10_* — dump that product's repos
# with everything needed to recreate them for aarch64.
prod = Katello::Product.where(organization_id: org.id, label: 'AlmaLinux_10').first
if prod.nil?
  puts "\nNO product labelled AlmaLinux_10 — list above and adjust the label."
else
  puts "\n=== repos in #{prod.label} (mirror each for aarch64) ==="
  prod.root_repositories.order(:id).each do |rr|
    content_label = "#{org.label}_#{prod.label}_#{rr.label}"
    puts "REPO\tname=#{rr.name.inspect}\tlabel=#{rr.label}\ttype=#{rr.content_type}\t" \
         "arch=#{rr.arch.inspect}\tpolicy=#{rr.download_policy.inspect}\t" \
         "gpg=#{rr.gpg_key&.name.inspect}\tcontent_label=#{content_label}"
    puts "  url=#{rr.url.inspect}"
  end
end

puts "\n=== GPG keys (org) — reuse these for the aarch64 repos ==="
Katello::GpgKey.where(organization_id: org.id).order(:id).each do |g|
  puts "GPG\tid=#{g.id}\tname=#{g.name.inspect}"
end

puts "\n=== 'AlmaLinux 10' activation key — the aarch64 key should mirror env/CV ==="
ak = Katello::ActivationKey.where(organization_id: org.id, name: 'AlmaLinux 10').first
if ak.nil?
  puts "NO key named 'AlmaLinux 10' — list all:"
  Katello::ActivationKey.where(organization_id: org.id).each { |k| puts "AK\t#{k.id}\t#{k.name}" }
else
  puts "AK\tid=#{ak.id}\tname=#{ak.name.inspect}\tenv=#{ak.environment&.label.inspect}\t" \
       "cv=#{ak.content_view&.label.inspect}\tunlimited=#{ak.unlimited_hosts}\t" \
       "max=#{ak.max_hosts.inspect}\tservice_level=#{ak.service_level.inspect}"
  begin
    puts "OVERRIDES\t#{ak.content_overrides.map { |o| "#{o.content_label}=#{o.value}" }.join(', ')}"
  rescue => e
    puts "OVERRIDES_ERR\t#{e.class}: #{e.message.to_s[0,120]}"
  end
end
exit
