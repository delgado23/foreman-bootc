# Allow image-mode hosts to pull the bootc image from the Katello registry
# during Anaconda %pre without credentials, by enabling unauthenticated pull
# on the Library lifecycle environment (id 2, org Garaventaville).
User.current = User.unscoped.find_by!(login: 'admin')

env = Katello::KTEnvironment.find(2)
env.update!(registry_unauthenticated_pull: true)
puts "ENV_UPDATED\t#{env.name}\tunauth_pull=#{env.reload.registry_unauthenticated_pull}"

# The dedicated pull user is no longer needed.
u = User.unscoped.find_by(login: 'bootc-pull')
if u
  u.destroy!
  puts "DELETED_USER\tbootc-pull"
else
  puts "NO_PULL_USER"
end
exit
