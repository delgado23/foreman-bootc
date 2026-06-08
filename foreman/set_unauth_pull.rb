# Move install-time anonymous (unauthenticated) registry pull from Library to
# Production, so only smoke-tested, CV-promoted content is anonymously pullable
# at install time. Anaconda's %pre pulls before the host registers, so the
# install-time environment must allow unauthenticated pull.
#
# Run on foreman:  sudo foreman-rake console < foreman/set_unauth_pull.rb
#
# SAFE ROLLOUT — Production is always enabled here. Library is only disabled when
# you are ready (after a test host provisions from the Production path):
#   1st pass (Production live, Library still pullable):  KEEP_LIBRARY_PULL=1 ...
#   final pass (lock Library down):                      (no env var)
#
# Replaces the old enable_unauth_pull.rb (which enabled pull on Library).
User.current = User.unscoped.find_by!(login: 'admin')
org = Organization.unscoped.find(4)

prod = Katello::KTEnvironment.find_by!(organization_id: org.id, label: 'Production')
lib  = Katello::KTEnvironment.find_by!(organization_id: org.id, label: 'Library')

prod.update!(registry_unauthenticated_pull: true)
puts "ENV_UPDATED\t#{prod.name}\tunauth_pull=#{prod.reload.registry_unauthenticated_pull}"

if ENV['KEEP_LIBRARY_PULL'] == '1'
  puts "ENV_LEFT\t#{lib.name}\tunauth_pull=#{lib.registry_unauthenticated_pull} (KEEP_LIBRARY_PULL=1)"
else
  lib.update!(registry_unauthenticated_pull: false)
  puts "ENV_UPDATED\t#{lib.name}\tunauth_pull=#{lib.reload.registry_unauthenticated_pull}"
end
exit
