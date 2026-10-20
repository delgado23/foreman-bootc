# Behaviour tests for foreman/setup_proxmox_firmware.rb, run under plain Ruby
# against the fakes in tests/fake_foreman.rb. Each case runs the real script in
# a fresh `ruby` process, as `foreman-rake console < script` would, with state
# carried between runs in a JSON file.
#   ruby tests/test_setup_proxmox_firmware.rb
require 'json'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
SCRIPT = File.join(ROOT, 'foreman/setup_proxmox_firmware.rb')
FAKES = File.join(ROOT, 'tests/fake_foreman.rb')
SB = 'Grub2 UEFI SecureBoot'
OLD = 'Grub2 UEFI'
PROFILES = { 4 => 'Proxmox-Small', 5 => 'Proxmox-Medium', 6 => 'Kubernetes Worker Node', 8 => 'Kubernetes Controlplane Node' }.freeze
OTHER_PROFILE = { 1 => '1-Small' }.freeze

$failures = []
$checks = 0

def check(label, ok)
  $checks += 1
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  $failures << label unless ok
end

def vm_attrs(bios: 'ovmf')
  { 'type' => 'qemu', 'node_id' => 'pve-01',
    'config_attributes' => { 'bios' => bios, 'is_secure_boot' => '0', 'cores' => '2', 'cpu_type' => 'x86-64-v3', 'boot' => 'order=net0;virtio0' },
    'volumes_attributes' => { '0' => { 'id' => 'virtio0', 'storage' => 'linstor', 'size' => '36' } } }
end

# The original state, before the script ever ran.
def initial_state(plugin_version: '1.0.0', bios: 'ovmf', bad_bios_profile: 4)
  {
    'plugin_version' => plugin_version,
    'compute_resources' => [{ 'id' => 1, 'name' => 'Proxmox' }],
    'compute_profiles' => PROFILES.merge(OTHER_PROFILE).map { |id, name| { 'id' => id, 'name' => name } },
    'compute_attributes' => PROFILES.merge(OTHER_PROFILE).keys.map do |id|
      { 'compute_resource_id' => 1, 'compute_profile_id' => id, 'vm_attrs' => vm_attrs(bios: id == bad_bios_profile ? bios : 'ovmf') }
    end,
    'hostgroups' => [
      { 'id' => 22, 'title' => 'AlmaLinux 9', 'parent_id' => nil, 'pxe_loader' => OLD },
      { 'id' => 24, 'title' => 'AlmaLinux 10', 'parent_id' => nil, 'pxe_loader' => OLD },
      { 'id' => 25, 'title' => 'AlmaLinux 10/DMZ', 'parent_id' => 24, 'pxe_loader' => '' },
      { 'id' => 29, 'title' => 'AlmaLinux 10/Kubernetes Controlplane Node', 'parent_id' => 24, 'pxe_loader' => '' },
      { 'id' => 30, 'title' => 'AlmaLinux 10/Kubernetes Worker Node', 'parent_id' => 24, 'pxe_loader' => '' },
      { 'id' => 31, 'title' => 'AlmaLinux 10/Image Mode', 'parent_id' => 24, 'pxe_loader' => '' },
      { 'id' => 33, 'title' => 'Windows 11', 'parent_id' => nil, 'pxe_loader' => 'None' },
    ],
    'hosts' => [
      { 'name' => 'inherits.example', 'hostgroup_id' => 24, 'pxe_loader' => nil },
      { 'name' => 'stored.example', 'hostgroup_id' => 24, 'pxe_loader' => OLD },
      { 'name' => 'windows.example', 'hostgroup_id' => 33, 'pxe_loader' => nil },
    ],
  }
end

def run(state_path, env = {})
  prelude = env.map { |k, v| "ENV['#{k}']='#{v}'\n" }.join
  out, status = Open3.capture2e({ 'FAKE_STATE' => state_path }, 'ruby', '-r', FAKES, '-e', prelude + File.read(SCRIPT))
  [out, status, JSON.parse(File.read(state_path))]
end

def cfg(state, profile_id)
  state['compute_attributes'].find { |c| c['compute_profile_id'] == profile_id }['vm_attrs']['config_attributes']
end

def loader(state, hg_id)
  state['hostgroups'].find { |h| h['id'] == hg_id }['pxe_loader']
end

def firmware(state)
  PROFILES.keys.to_h { |id| [id, [cfg(state, id)['is_secure_boot'], cfg(state, id)['rng0']]] }
end

def loaders(state)
  [22, 24, 29, 30].to_h { |id| [id, loader(state, id)] }
end

Dir.mktmpdir do |dir|
  path = File.join(dir, 'state.json')
  pristine = initial_state

  # 1. Dry run changes nothing.
  File.write(path, JSON.generate(pristine))
  out, st, s = run(path, 'FW_DRY_RUN' => '1')
  check('dry run exits 0', st.success?)
  check('dry run plans all four profiles', PROFILES.values.all? { |n| out.include?("PROFILE\t#{n}\t{\"is_secure_boot\":\"0\",\"rng0\":null} -> {\"is_secure_boot\":\"1\",\"rng0\":\"source=/dev/urandom\"}") })
  check('dry run changes no state', s == pristine)

  # 2. Apply.
  out, st, s = run(path)
  check('apply exits 0', st.success?)
  check('apply turns on Secure Boot and rng0 on all four profiles', firmware(s).values.uniq == [['1', 'source=/dev/urandom']])
  check('apply leaves other config attributes alone',
        PROFILES.keys.all? { |id| cfg(s, id).reject { |k, _| %w[is_secure_boot rng0].include?(k) } == cfg(pristine, id).reject { |k, _| k == 'is_secure_boot' } })
  check('apply leaves volumes and other vm_attrs alone',
        PROFILES.keys.all? { |id| s['compute_attributes'].find { |c| c['compute_profile_id'] == id }['vm_attrs'].reject { |k, _| k == 'config_attributes' } ==
                                    pristine['compute_attributes'].find { |c| c['compute_profile_id'] == id }['vm_attrs'].reject { |k, _| k == 'config_attributes' } })
  check('apply leaves profiles outside the list alone', cfg(s, 1) == cfg(pristine, 1))
  check('apply sets 22/24 to SecureBoot and 29/30 to inherit', loaders(s) == { 22 => SB, 24 => SB, 29 => '', 30 => '' })
  check('apply leaves other host groups alone', loader(s, 25) == '' && loader(s, 31) == '' && loader(s, 33) == 'None')
  check('apply lists hosts that inherit their loader', out.include?("INHERITS\tinherits.example\thostgroup=AlmaLinux 10\teffective=\"#{SB}\""))
  check('apply does not list hosts with a stored loader', !out.include?('stored.example'))
  check('apply does not list hosts outside 22/24', !out.include?('windows.example'))

  # 3. Re-apply is a no-op.
  before = JSON.parse(File.read(path))
  out, st, s = run(path)
  check('re-apply exits 0', st.success?)
  check('re-apply reports every profile unchanged', PROFILES.values.all? { |n| out.include?("PROFILE\t#{n}\tunchanged") })
  check('re-apply reports every host group unchanged', out.scan(/^HOSTGROUP\t.*\tunchanged\t/).size == 4)
  check('re-apply leaves state identical', s == before)

  # 4. Rollback dry run changes nothing; rollback restores the original state.
  out, st, s = run(path, 'FW_ROLLBACK' => '1', 'FW_DRY_RUN' => '1')
  check('rollback dry run exits 0', st.success?)
  check('rollback dry run changes no state', s == before)
  out, st, s = run(path, 'FW_ROLLBACK' => '1')
  check('rollback exits 0', st.success?)
  check('rollback turns Secure Boot off and removes rng0', firmware(s).values.uniq == [['0', nil]] && PROFILES.keys.none? { |id| cfg(s, id).key?('rng0') })
  check('rollback restores the original host group loaders', loaders(s) == { 22 => OLD, 24 => OLD, 29 => '', 30 => '' })
  check('rollback returns to the original state', s == pristine)

  # 5. A profile subset with host groups untouched (how throwaway test copies are prepared).
  File.write(path, JSON.generate(pristine))
  out, st, s = run(path, 'FW_PROFILES' => 'Kubernetes Worker Node', 'FW_HOSTGROUPS' => '0')
  check('subset exits 0', st.success?)
  check('subset changes only the named profile',
        firmware(s) == { 4 => ['0', nil], 5 => ['0', nil], 6 => ['1', 'source=/dev/urandom'], 8 => ['0', nil] })
  check('FW_HOSTGROUPS=0 leaves host groups alone', loaders(s) == loaders(pristine) && !out.include?('HOSTGROUP'))

  # 6. Guards abort before changing anything, wherever the problem is: every
  #    profile and host group is resolved and validated before the first write.
  no_hg30 = initial_state.tap { |h| h['hostgroups'].reject! { |g| g['id'] == 30 } }
  [['plugin 1.1.0', initial_state(plugin_version: '1.1.0'), {}, 'not 1.0.x'],
   ['plugin missing', initial_state.tap { |h| h.delete('plugin_version') }, {}, 'not 1.0.x'],
   ['bios not ovmf on the first profile', initial_state(bios: 'seabios', bad_bios_profile: 4), {}, 'Proxmox-Small: expected bios=ovmf'],
   ['bios not ovmf on a later profile', initial_state(bios: 'seabios', bad_bios_profile: 6), {}, 'Kubernetes Worker Node: expected bios=ovmf'],
   ['bios not ovmf on the last profile', initial_state(bios: 'seabios', bad_bios_profile: 8), {}, 'Kubernetes Controlplane Node: expected bios=ovmf'],
   ['a later profile missing', initial_state, { 'FW_PROFILES' => 'Proxmox-Small,No Such Profile' }, 'record not found'],
   ['a host group missing', no_hg30, {}, 'hostgroup 30 not found']].each do |label, state, env, message|
    File.write(path, JSON.generate(state))
    out, st, s = run(path, env)
    check("guard (#{label}): aborts non-zero", !st.success?)
    check("guard (#{label}): names the problem", out.include?(message))
    check("guard (#{label}): state unchanged", s == state)
    check("guard (#{label}): reports no change", !out.match?(/^(PROFILE|HOSTGROUP)\t/))
  end

  # 7. A write that fails inside the transaction leaves nothing behind.
  File.write(path, JSON.generate(pristine))
  out, st, s = run(path, 'FAIL_HOSTGROUP_SAVE' => '1')
  check('failed host group save: aborts non-zero', !st.success?)
  check('failed host group save: profile writes rolled back', s == pristine)
end

puts
if $failures.empty?
  puts "OK: all #{$checks} checks passed"
else
  puts "FAILED: #{$failures.size} of #{$checks} checks"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
