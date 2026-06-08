# Read-only inspection for the bootc content-view gating work.
#
# Run on foreman:  sudo foreman-rake console < foreman/ops/inspect_content_view.rb
#
# Confirms two facts the gating design depends on (and which the docs do not pin
# down for Katello 4.20.1), then prints the data the follow-up scripts/templates
# need:
#   1. that the bootc PUSH repositories can/do live in a content view, and
#   2. the EXACT env/CV-qualified registry pull path promoted content gets
#      (the `ostreecontainer` install ref must match this verbatim).
# Makes no changes.
User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

puts "=== lifecycle environments (org #{org.name}) ==="
Katello::KTEnvironment.where(organization_id: org.id).order(:id).each do |e|
  puts "ENV\tid=#{e.id}\tlabel=#{e.label}\tname=#{e.name}\tlibrary=#{e.library?}\tunauth_pull=#{e.registry_unauthenticated_pull}"
end

puts "\n=== bootc product repositories ==="
prod = Katello::Product.where(organization_id: org.id, label: 'bootc').first
if prod.nil?
  puts "NO_BOOTC_PRODUCT"
else
  prod.repositories.order(:id).each do |r|
    rr = r.root
    puts "REPO\tid=#{r.id}\tname=#{rr&.name}\tcontent_type=#{rr&.content_type}\t" \
         "is_push=#{!!rr&.is_container_push}\tenv=#{r.environment&.label.inspect}\t" \
         "cv=#{r.content_view&.label.inspect}\tcontainer_repository_name=#{r.container_repository_name.inspect}"
  end
end

puts "\n=== content views named like bootc (idempotency) ==="
Katello::ContentView.where(organization_id: org.id).where("name ILIKE ? OR label ILIKE ?", "%bootc%", "%bootc%").each do |cv|
  puts "CV\tid=#{cv.id}\tlabel=#{cv.label}\tname=#{cv.name}\tcomposite=#{cv.composite?}\t" \
       "repos=#{cv.repositories.count}\tversions=#{cv.versions.count}"
  cv.versions.order(:id).each do |v|
    envs = v.environments.map(&:label).join(',')
    puts "  CVV\tversion=#{v.version}\tenvironments=[#{envs}]"
  end
end

puts "\n=== feasibility: can a push repo be added to a CV here? ==="
# A push repo's root carries a `container_push_name`; the CV repo association is
# the same `content_view.repositories` collection used for synced repos. If the
# association rejects push repos this Katello build, it shows up as a validation
# error when setup_content_view.rb adds them. Report the column so we know the
# push repos are identifiable.
begin
  pushers = Katello::RootRepository.where(product_id: prod&.id, content_type: 'docker')
                                   .select { |rr| rr.respond_to?(:is_container_push) && rr.is_container_push }
  puts "PUSH_REPOS\tcount=#{pushers.size}\t#{pushers.map(&:name).join(', ')}"
rescue => e
  puts "PUSH_DETECT_ERR\t#{e.class}: #{e.message.to_s[0, 200]}"
end

puts "\n=== promoted container pull paths (if a bootc CV is already promoted) ==="
cv = Katello::ContentView.where(organization_id: org.id, label: 'bootc').first
if cv
  Katello::KTEnvironment.where(organization_id: org.id).order(:id).each do |e|
    Katello::Repository.in_environment(e).in_content_views([cv]).each do |r|
      puts "PATH\tenv=#{e.label}\tpull=foreman.garaventaville.com/#{r.container_repository_name}"
    end
  end
else
  puts "NO_BOOTC_CV_YET (run setup_content_view.rb, then re-run this to read the Production path)"
end
exit
