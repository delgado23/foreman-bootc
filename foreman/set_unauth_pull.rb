# Move install-time anonymous (unauthenticated) registry pull from Library to
# Production, so only smoke-tested, CV-promoted content is anonymously pullable
# at install time. Anaconda's %pre pulls before the host registers, so the
# install-time environment must allow unauthenticated pull.
#
# Run on foreman:  sudo foreman-rake console < foreman/set_unauth_pull.rb
#
# SAFE BY DEFAULT / SELF-SEQUENCING — Production is always enabled. Library is
# only locked down (unauth_pull=false) once the install-time refs have actually
# moved to Production, detected by the "AlmaLinux 10/Image Mode" host group's
# `ostreecontainer` param pointing at a Production path. Until then Library is
# left pullable so in-flight bootc provisions don't break. So the order is just:
#   1. setup_content_view.rb         (publish + promote to Production)
#   2. set_unauth_pull.rb            (enables Production; Library kept — refs not moved yet)
#   3. setup_image_mode_hostgroup.rb + setup_kubernetes_image_mode.rb  (move refs)
#   4. set_unauth_pull.rb            (now locks Library down)
# (env vars are not used: foreman-rake switches to the foreman user and strips them.)
#
# Replaces the old enable_unauth_pull.rb (which enabled pull on Library).
User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

prod = Katello::KTEnvironment.find_by!(organization_id: org.id, label: 'Production')
lib  = Katello::KTEnvironment.find_by!(organization_id: org.id, label: 'Library')

prod.update!(registry_unauthenticated_pull: true)
puts "ENV_UPDATED\t#{prod.name}\tunauth_pull=#{prod.reload.registry_unauthenticated_pull}"

# Have the install-time refs moved to Production yet? Gate the Library lockdown on
# the Image Mode host group's ostreecontainer param.
im = Hostgroup.unscoped.find_by(name: 'Image Mode')
ref = im&.group_parameters&.find_by(name: 'ostreecontainer')&.value.to_s
refs_moved = ref.include?('/production/')

if refs_moved
  lib.update!(registry_unauthenticated_pull: false)
  puts "ENV_UPDATED\t#{lib.name}\tunauth_pull=#{lib.reload.registry_unauthenticated_pull}"
else
  puts "ENV_KEPT\t#{lib.name}\tunauth_pull=#{lib.registry_unauthenticated_pull} " \
       "(install refs still on Library: #{ref.inspect} — run setup_image_mode_hostgroup.rb / " \
       "setup_kubernetes_image_mode.rb, then re-run this to lock Library down)"
end
exit
