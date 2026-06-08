# Create the gated "bootc" content view and establish the Library -> Production
# promotion path for the four bootc PUSH repositories.
#
# Run on foreman:  sudo foreman-rake console < foreman/setup_content_view.rb
#
# Idempotent (find-or-create + find-or-add). Run foreman/ops/inspect_content_view.rb
# FIRST to confirm the push repos are CV-eligible on this Katello build. After this
# runs, re-run the inspector to read the promoted Production pull path that the
# install-time refs (setup_image_mode_hostgroup.rb / setup_kubernetes_image_mode.rb)
# consume.
#
# Model: images are still `podman push`ed into the bootc product (Library). This CV
# snapshots that Library content; promotion to Production is the smoke-test gate
# (done weekly by main.yml, not here — here we just create the objects + seed an
# initial promoted version).
User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

IMAGES = %w[almalinux10-bootc kubernetes-common kubernetes-controlplane kubernetes-worker].freeze

product = Katello::Product.where(organization_id: org.id, label: 'bootc').first
abort "NO_BOOTC_PRODUCT — create it first (foreman/create_product.rb)" if product.nil?

# 1. Find-or-create the content view.
cv = Katello::ContentView.find_by(organization_id: org.id, label: 'bootc')
if cv.nil?
  cv = Katello::ContentView.create!(name: 'bootc', label: 'bootc', organization: org)
  puts "NEW_CV\tid=#{cv.id}\tlabel=#{cv.label}"
else
  puts "CV_EXISTS\tid=#{cv.id}\tlabel=#{cv.label}"
end

# 2. Add the four bootc push repositories (their Library instances) to the CV.
library_repos = product.repositories.in_default_view.select do |r|
  IMAGES.include?(r.root&.name)
end
library_repos.each do |r|
  if cv.repositories.include?(r)
    puts "REPO_ALREADY\t#{r.root.name}"
  else
    cv.repositories << r
    puts "REPO_ADDED\t#{r.root.name}\tid=#{r.id}"
  end
end
cv.save!
missing = IMAGES - library_repos.map { |r| r.root&.name }
puts "MISSING_REPOS\t#{missing.join(', ')} (push them first)" unless missing.empty?

# 3. Publish a version (snapshots current Library push content) via dynflow.
puts "PUBLISHING…"
ForemanTasks.sync_task(::Actions::Katello::ContentView::Publish, cv, 'initial gated publish')
cv.reload
version = cv.versions.order(:version).last
puts "PUBLISHED\tversion=#{version.version}\tid=#{version.id}"

# 4. Promote that version to Production to establish the install-time path.
prod_env = Katello::KTEnvironment.find_by!(organization_id: org.id, label: 'Production')
if version.environments.include?(prod_env)
  puts "ALREADY_IN_PROD\tversion=#{version.version}"
else
  puts "PROMOTING -> Production…"
  ForemanTasks.sync_task(::Actions::Katello::ContentView::Promote, version, [prod_env])
  puts "PROMOTED\tversion=#{version.version}\t-> #{prod_env.label}"
end

# 5. Print the promoted pull paths — copy these into the install-time refs.
puts "\n=== promoted pull paths (use as ostreecontainer base) ==="
Katello::Repository.in_environment(prod_env).in_content_views([cv]).each do |r|
  puts "PROD_PATH\t#{r.root&.name}\tforeman.garaventaville.com/#{r.container_repository_name}"
end
exit
