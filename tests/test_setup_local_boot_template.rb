# Behaviour tests for foreman/setup_local_boot_template.rb, run under plain Ruby
# against the fakes in tests/fake_foreman.rb. Each case runs the real script in
# a fresh `ruby` process, as `foreman-rake console < script` would, with state
# carried between runs in a JSON file.
#   ruby tests/test_setup_local_boot_template.rb
require 'json'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
SCRIPT = File.join(ROOT, 'foreman/setup_local_boot_template.rb')
FAKES = File.join(ROOT, 'tests/fake_foreman.rb')
STOCK = 'PXEGrub2 default local boot'
CLONE = 'PXEGrub2 local boot (3s timeout)'
STOCK_BODY = <<~ERB
  <%#
  kind: PXEGrub2
  name: #{STOCK}
  model: ProvisioningTemplate
  description: |
    The template to render Grub2 bootloader configuration for provisioned hosts,
    that still boot from the network.
    Hosts are instructed to boot from the first local medium.
    Do not associate or change the name.
  -%>
  set default=<%= global_setting("default_pxe_item_local", "local") %>
  set timeout=20
  echo Default PXE local template entry is set to '<%= global_setting("default_pxe_item_local", "local") %>'

  <%= snippet "pxegrub2_chainload" %>
  <%= snippet "pxegrub2_discovery" %>
ERB

$failures = []
$checks = 0

def check(label, ok)
  $checks += 1
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  $failures << label unless ok
end

def initial_state(stock_body: STOCK_BODY, parameters: [])
  {
    'locations' => [{ 'id' => 3, 'name' => 'Leland, NC' }, { 'id' => 5, 'name' => 'Default Location' }],
    'organizations' => [{ 'id' => 4, 'name' => 'Garaventaville', 'location_ids' => [3, 5] }],
    'templates' => [{ 'name' => STOCK, 'template' => stock_body, 'template_kind' => 'PXEGrub2', 'snippet' => false,
                      'locked' => true, 'organization_ids' => [4], 'location_ids' => [5] }],
    'settings' => { 'local_boot_PXEGrub2' => STOCK },
    'parameters' => parameters,
  }
end

# Run the script once; env entries become ENV['...']='...' lines prepended to
# stdin, exactly as the README documents for foreman-rake.
def run(state_path, env = {})
  prelude = env.map { |k, v| "ENV['#{k}']='#{v}'\n" }.join
  code = prelude + File.read(SCRIPT)
  out, status = Open3.capture2e({ 'FAKE_STATE' => state_path }, 'ruby', '-r', FAKES, '-e', code)
  [out, status, JSON.parse(File.read(state_path))]
end

def template(state, name)
  state['templates'].find { |t| t['name'] == name }
end

Dir.mktmpdir do |dir|
  path = File.join(dir, 'state.json')

  # 1. Dry run changes nothing.
  File.write(path, JSON.generate(initial_state))
  out, st, s = run(path, 'LB_DRY_RUN' => '1')
  check('dry run exits 0', st.success?)
  check('dry run reports a create', out.include?("TEMPLATE\t#{CLONE}\tcreate"))
  check('dry run reports the setting change', out.include?("SETTING\tlocal_boot_PXEGrub2\t\"#{STOCK}\" -> \"#{CLONE}\""))
  check('dry run creates no template', template(s, CLONE).nil?)
  check('dry run leaves the setting', s['settings']['local_boot_PXEGrub2'] == STOCK)

  # 2. Apply creates the clone and points the setting at it.
  out, st, s = run(path)
  clone = template(s, CLONE)
  stock = template(s, STOCK)
  check('apply exits 0', st.success?)
  check('apply creates the clone', !clone.nil?)
  check('clone has the 3 s timeout', clone && clone['template'].lines.include?("set timeout=3\n"))
  check('clone has no 20 s timeout left', clone && !clone['template'].include?('set timeout=20'))
  check('clone differs from stock only in timeout and metadata',
        clone && clone['template'].lines.size == STOCK_BODY.lines.size + 1 &&
        (clone['template'].lines - STOCK_BODY.lines).size == 4)
  check('clone is named in its own metadata', clone && clone['template'].include?("name: #{CLONE}\n"))
  check('clone keeps the chainload and discovery snippets',
        clone && clone['template'].include?('<%= snippet "pxegrub2_chainload" %>') && clone['template'].include?('<%= snippet "pxegrub2_discovery" %>'))
  check('clone is a PXEGrub2, unlocked, non-snippet template',
        clone && clone['template_kind'] == 'PXEGrub2' && clone['locked'] == false && clone['snippet'] == false)
  check('clone gets the org and every org location', clone && clone['organization_ids'] == [4] && clone['location_ids'].sort == [3, 5])
  check('stock template is untouched', stock == initial_state['templates'].first)
  check('setting points at the clone', s['settings']['local_boot_PXEGrub2'] == CLONE)
  check('no overrides reported', out.include?("OVERRIDES\tnone"))

  # 3. Re-apply is a no-op.
  before = File.read(path)
  out, st, s = run(path)
  check('re-apply exits 0', st.success?)
  check('re-apply reports the template unchanged', out.include?("TEMPLATE\t#{CLONE}\tunchanged"))
  check('re-apply reports the setting unchanged', out.include?("SETTING\tlocal_boot_PXEGrub2\tunchanged"))
  check('re-apply leaves state identical', JSON.parse(before) == s)

  # 4. Rollback dry run changes nothing; rollback restores the setting, keeps the clone.
  out, st, s = run(path, 'LB_ROLLBACK' => '1', 'LB_DRY_RUN' => '1')
  check('rollback dry run exits 0', st.success?)
  check('rollback dry run leaves the setting', s['settings']['local_boot_PXEGrub2'] == CLONE)
  out, st, s = run(path, 'LB_ROLLBACK' => '1')
  check('rollback exits 0', st.success?)
  check('rollback restores the stock setting', s['settings']['local_boot_PXEGrub2'] == STOCK)
  check('rollback keeps the clone', !template(s, CLONE).nil?)
  check('rollback does not report a template action', !out.include?("TEMPLATE\t"))

  # 5. A drifted clone is repaired.
  s['templates'].find { |t| t['name'] == CLONE }['template'] = 'tampered'
  File.write(path, JSON.generate(s))
  out, st, s = run(path)
  check('drifted clone reported as update', out.include?("TEMPLATE\t#{CLONE}\tupdate"))
  check('drifted clone repaired', template(s, CLONE)['template'].include?("set timeout=3\n"))

  # 6. The guard: stock without exactly one 'set timeout=20' aborts with no changes.
  [STOCK_BODY.sub("set timeout=20\n", ''), STOCK_BODY.sub("set timeout=20\n", "set timeout=20\nset timeout=20\n")].each_with_index do |body, i|
    File.write(path, JSON.generate(initial_state(stock_body: body)))
    before = File.read(path)
    out, st, = run(path)
    check("guard #{i + 1}: aborts non-zero", !st.success?)
    check("guard #{i + 1}: names the problem", out.include?("expected exactly one 'set timeout=20'"))
    check("guard #{i + 1}: state unchanged", JSON.parse(before) == JSON.parse(File.read(path)))
  end

  # 7. A parameter that overrides the setting is reported.
  File.write(path, JSON.generate(initial_state(parameters: [{ 'name' => 'local_boot_PXEGrub2', 'type' => 'CommonParameter', 'reference_id' => nil, 'value' => 'Other' }])))
  out, = run(path, 'LB_DRY_RUN' => '1')
  check('override parameter reported', out.include?("OVERRIDES\tCommonParameter:=Other"))
end

puts
if $failures.empty?
  puts "OK: all #{$checks} checks passed"
else
  puts "FAILED: #{$failures.size} of #{$checks} checks"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
